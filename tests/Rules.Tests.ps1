#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src\AutopilotDashboard.psm1') -Force
    $script:rulesPath = Join-Path $root 'rules.json'
    $script:rules = Import-AdRules -Path $rulesPath
    function New-Ev($kind, $key, $value, $source = 'test') { [ordered]@{ source = $source; kind = $kind; key = $key; value = $value; detail = ''; time = $null } }
}

Describe 'rules.json' {
    It 'loads and validates' {
        $rules.Count | Should -BeGreaterThan 15
    }

    It 'every rule has all required fields and a Microsoft Learn source' {
        foreach ($r in $rules) {
            foreach ($f in 'id', 'phase', 'signal', 'likelyCause', 'recommendedFix', 'structuralAction', 'confidence', 'sourceUrl') {
                [string]::IsNullOrWhiteSpace([string]$r.$f) | Should -BeFalse -Because "$($r.id).$f is required"
            }
            $r.sourceUrl | Should -Match '^https://learn\.microsoft\.com/'
            $r.confidence | Should -BeIn 'high', 'medium', 'low'
            $r.verification.checked | Should -Not -BeNullOrEmpty -Because "$($r.id) must record when it was verified"
        }
    }

    It 'covers required event ID <_>' -ForEach @(807, 809, 815, 908, 171, 172) {
        $id = $_
        @($rules | Where-Object { $_.signal.type -eq 'eventId' -and $id -in $_.signal.values }).Count | Should -BeGreaterThan 0
    }

    It 'covers required error code <_>' -ForEach @('801C0003', '80180018', '0x80180014', '0x80070774', '0x800705b4', '0x87d1041c') {
        $code = ConvertTo-AdHexCode $(if ($_ -like '0x*') { $_ } else { "0x$_" })
        @($rules | Where-Object { $_.signal.type -eq 'errorCode' -and $code -in @($_.signal.values | ForEach-Object { ConvertTo-AdHexCode $_ }) }).Count | Should -BeGreaterThan 0
    }

    It 'covers InstallationState = 4, "Another installation is in progress", IsAutopilotDisabled = 1 and TenantMatched = 0' {
        @($rules | Where-Object { $_.signal.type -eq 'espInstallationState' -and [int]$_.signal.equals -eq 4 }).Count | Should -BeGreaterThan 0
        @($rules | Where-Object { $_.signal.type -eq 'text' -and 'Another installation is in progress, please try again later.' -match $_.signal.pattern }).Count | Should -BeGreaterThan 0
        @($rules | Where-Object { $_.signal.type -eq 'registryValue' -and $_.signal.name -eq 'IsAutopilotDisabled' -and [int]$_.signal.equals -eq 1 }).Count | Should -BeGreaterThan 0
        @($rules | Where-Object { $_.signal.type -eq 'registryValue' -and $_.signal.name -eq 'TenantMatched' -and [int]$_.signal.equals -eq 0 }).Count | Should -BeGreaterThan 0
    }

    It 'rejects a rule with a missing field' {
        $tmp = Join-Path $TestDrive 'bad.json'
        @{ rules = @(@{ id = 'X'; phase = 'OOBE and network'; signal = @{ type = 'eventId'; values = @(1) }; likelyCause = 'c'; recommendedFix = 'f'; confidence = 'high'; sourceUrl = 'https://learn.microsoft.com/x' }) } | ConvertTo-Json -Depth 5 | Set-Content $tmp
        { Import-AdRules -Path $tmp } | Should -Throw '*structuralAction*'
    }

    It 'rejects a non-Microsoft source URL and an unknown signal type' {
        $tmp = Join-Path $TestDrive 'bad2.json'
        $base = @{ id = 'X'; phase = 'OOBE and network'; likelyCause = 'c'; recommendedFix = 'f'; structuralAction = 's'; confidence = 'high' }
        $r1 = $base.Clone(); $r1.signal = @{ type = 'eventId'; values = @(1) }; $r1.sourceUrl = 'https://example.com/'
        @{ rules = @($r1) } | ConvertTo-Json -Depth 5 | Set-Content $tmp
        { Import-AdRules -Path $tmp } | Should -Throw '*learn.microsoft.com*'
        $r2 = $base.Clone(); $r2.signal = @{ type = 'magic' }; $r2.sourceUrl = 'https://learn.microsoft.com/x'
        @{ rules = @($r2) } | ConvertTo-Json -Depth 5 | Set-Content $tmp
        { Import-AdRules -Path $tmp } | Should -Throw '*unknown signal type*'
    }
}

Describe 'Rule matching' {
    It 'matches event 807 from log evidence' {
        $f = Find-AdRuleMatches -Evidence @(New-Ev 'eventId' 'Event 807' 807) -Rules $rules
        $f.ruleId | Should -Contain 'AP-EVT-807'
        $f[0].label | Should -Be 'Likely cause'
    }

    It 'normalises error codes in any notation (<_>)' -ForEach @('0x87d1041c', '87D1041C', -2016345060, '-2016345060') {
        ConvertTo-AdHexCode $_ | Should -Be '0x87D1041C'
    }

    It 'shows multiple possible causes for the ambiguous 0x800705B4 when the context is unknown' {
        $f = Find-AdRuleMatches -Evidence @(New-Ev 'errorCode' 'x' '0x800705B4') -Rules $rules
        $f.Count | Should -BeGreaterOrEqual 3
        $f | ForEach-Object { $_.ambiguous | Should -BeTrue; $_.label | Should -Be 'Possible cause' }
    }

    It 'excludes the TPM explanation for 0x800705B4 in a user-driven ESP failure' {
        $f = Find-AdRuleMatches -Evidence @(New-Ev 'errorCode' 'x' '0x800705B4') -Rules $rules -FlowTags @('userDriven', 'entra') -GraphPhase 'ESP: device setup'
        $f.ruleId | Should -Not -Contain 'ERR-800705B4-TPM'
        $f.ruleId | Should -Contain 'ERR-800705B4-ESPTIMEOUT'
        $f.Count | Should -BeGreaterThan 1 -Because 'the generic timeout explanation must stay visible'
    }

    It 'ranks the TPM explanation first for a self-deploying failure' {
        $f = Find-AdRuleMatches -Evidence @(New-Ev 'errorCode' 'x' '0x800705B4') -Rules $rules -FlowTags @('selfDeploying', 'entra') -GraphPhase 'Entra join and MDM enrollment'
        $f[0].ruleId | Should -Be 'ERR-800705B4-TPM'
        $f[0].label | Should -Be 'Possible cause'
    }

    It 'never labels a finding as certain' {
        $all = Find-AdRuleMatches -Evidence @(
            (New-Ev 'eventId' 'e' 815), (New-Ev 'registryValue' 'TenantMatched' 0), (New-Ev 'espInstallationState' 'Win32App_1' 4),
            (New-Ev 'text' 'l' 'Another installation is in progress'), (New-Ev 'errorCode' 'c' '0x80180014')) -Rules $rules
        $all.label | Sort-Object -Unique | ForEach-Object { $_ | Should -BeIn 'Likely cause', 'Possible cause' }
        foreach ($f in $all) { $f.evidence.Count | Should -BeGreaterThan 0 -Because 'every finding cites evidence' }
    }

    It 'treats IsAutopilotDisabled = 1 as ambiguous (registration vs network)' {
        $f = Find-AdRuleMatches -Evidence @(New-Ev 'registryValue' 'IsAutopilotDisabled' 1) -Rules $rules
        $f.ruleId | Should -Contain 'REG-ISAUTOPILOTDISABLED-NOTREG'
        $f.ruleId | Should -Contain 'REG-ISAUTOPILOTDISABLED-NETWORK'
        $f | ForEach-Object { $_.ambiguous | Should -BeTrue }
    }

    It 'does not match TenantMatched = 1' {
        (Find-AdRuleMatches -Evidence @(New-Ev 'registryValue' 'TenantMatched' 1) -Rules $rules).Count | Should -Be 0
    }

    It 'ranks a specific error-code rule above the generic policy rule' {
        $f = Find-AdRuleMatches -Evidence @((New-Ev 'policyStatus' 'App' 'error'), (New-Ev 'errorCode' 'App' '0x80070652')) -Rules $rules
        $f[0].ruleId | Should -Be 'ERR-80070652-MSI-BUSY'
    }
}
