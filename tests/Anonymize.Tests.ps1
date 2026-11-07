#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src\AutopilotDashboard.psm1') -Force
    $script:key = [byte[]](1..32)
    $script:deps = @(
        [ordered]@{ id = '1'; upn = 'alex.kim@contoso.example'; deviceName = 'CTS-123456'; serial = 'CTSX123456'; enrollmentFailure = 'Device CTS-123456 (CTSX123456) for alex.kim@contoso.example failed'
            findings = @([ordered]@{ evidence = @([ordered]@{ detail = 'log line mentions CTS-123456 and ALEX.KIM@CONTOSO.EXAMPLE' }) }) }
        [ordered]@{ id = '2'; upn = $null; deviceName = 'KSK-1'; serial = 'AB'; enrollmentFailure = 'other.user@fabrikam.example' }
    )
}

Describe 'Anonymization' {
    It 'masks user names, device names and serial numbers everywhere, including free text' {
        $payload = @{ deployments = $deps }
        $vals = Get-AdSensitiveValues -Deployments $deps
        $out = Protect-AdPayload -Payload $payload -SensitiveValues $vals -Key $key
        $json = $out | ConvertTo-Json -Depth 20
        $json | Should -Not -Match 'alex\.kim'
        $json | Should -Not -Match 'CTS-123456'
        $json | Should -Not -Match 'CTSX123456'
        $json | Should -Not -Match 'other\.user@fabrikam'
        $json | Should -Not -Match 'KSK-1'
        $out.deployments[0].upn | Should -Match '^user-[0-9A-F]{6}$'
        $out.deployments[0].deviceName | Should -Match '^device-[0-9A-F]{6}$'
        $out.deployments[0].serial | Should -Match '^SN-[0-9A-F]{6}$'
    }

    It 'uses stable pseudonyms so the same device keeps one alias' {
        $vals = Get-AdSensitiveValues -Deployments $deps
        $out = Protect-AdPayload -Payload @{ deployments = $deps } -SensitiveValues $vals -Key $key
        $alias = $out.deployments[0].deviceName
        $out.deployments[0].enrollmentFailure | Should -Match ([regex]::Escape($alias))
        (Get-AdPseudonym -Value 'CTS-123456' -Prefix 'device' -Key $key) | Should -Be $alias
    }

    It 'uses a different alias with a different key (not reversible across runs)' {
        (Get-AdPseudonym -Value 'CTS-123456' -Prefix 'device' -Key $key) | Should -Not -Be (Get-AdPseudonym -Value 'CTS-123456' -Prefix 'device' -Key ([byte[]](32..63)))
    }

    It 'does not mask values shorter than 3 characters (avoids mangling unrelated text)' {
        $vals = Get-AdSensitiveValues -Deployments $deps
        $vals.Contains('AB') | Should -BeFalse
    }

    It 'masks exports when anonymized' {
        $vals = Get-AdSensitiveValues -Deployments $deps
        $masked = Protect-AdPayload -Payload @{ deployments = $deps } -SensitiveValues $vals -Key $key
        $csv = New-AdExport -Format csv -Deployments @($masked.deployments) -Meta @{ anonymized = $true }
        $text = [System.Text.Encoding]::UTF8.GetString($csv.Bytes)
        $text | Should -Not -Match 'alex\.kim|CTS-123456|CTSX123456'
        $json = New-AdExport -Format json -Deployments @($masked.deployments) -Meta @{ anonymized = $true }
        [System.Text.Encoding]::UTF8.GetString($json.Bytes) | Should -Not -Match 'alex\.kim|CTS-123456'
    }

    It 'masks the full app payload through Get-AdDataPayload' {
        $state = New-AdAppState -Config (Get-AdDefaultConfig) -RootPath (Split-Path -Parent $PSScriptRoot) -Rules (Import-AdRules (Join-Path (Split-Path -Parent $PSScriptRoot) 'rules.json'))
        Set-AdDemoData -AppState $state
        $plain = (Get-AdDataPayload -AppState $state) | ConvertTo-Json -Depth 30 -Compress
        $plain | Should -Match '@contoso\.example'
        $state.Anonymize = $true
        $masked = (Get-AdDataPayload -AppState $state) | ConvertTo-Json -Depth 30 -Compress
        $masked | Should -Not -Match '@contoso\.example'
        $masked | Should -Not -Match 'CTSDEMO0007'
    }
}

Describe 'CSV export safety' {
    It 'neutralises spreadsheet formula injection (<_>)' -ForEach @('=HYPERLINK("http://x")', '+1+1', '-2+3', '@SUM(A1)') {
        Protect-AdCsvCell $_ | Should -BeLike "'*"
    }
}
