#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src\AutopilotDashboard.psm1') -Force
    $script:rules = Import-AdRules -Path (Join-Path $root 'rules.json')
    function New-Ds($events, $policy = @{}, $identities = @(), $profiles = @{}) {
        [ordered]@{ mode = 'test'; events = $events; policyDetails = $policy; identities = $identities; profiles = $profiles; sources = @() }
    }
}

Describe 'Missing fields' {
    It 'treats a record without deploymentState as "Not available", not success or failure' {
        $m = ConvertTo-AdDeploymentModel -Dataset (New-Ds @([pscustomobject]@{ id = 'a' })) -Rules $rules
        $m.Count | Should -Be 1
        $m[0].status | Should -Be 'Not available'
        $m[0].phase | Should -Be 'Not available'
        $m[0].flow | Should -Be 'Not available'
        $m[0].durationSec | Should -BeNullOrEmpty
        $m[0].dataGaps | Should -Contain 'deploymentState'
    }

    It 'survives events with only some properties, nulls and Graph "0001-01-01" dates' {
        $ev = [pscustomobject]@{ id = 'b'; deploymentState = 'failure'; eventDateTime = '0001-01-01T00:00:00Z'; enrollmentFailureDetails = $null; deploymentTotalDuration = 'PT0S' }
        $m = ConvertTo-AdDeploymentModel -Dataset (New-Ds @($ev)) -Rules $rules
        $m[0].status | Should -Be 'Failed'
        $m[0].eventDateTime | Should -BeNullOrEmpty
        $m[0].durationSec | Should -BeNullOrEmpty
        $m[0].phase | Should -Be 'Not available'
        $m[0].policyDetailsLoaded | Should -BeFalse
    }

    It 'maps unknown enum values to Not available' {
        (Get-AdStatus ([pscustomobject]@{ deploymentState = 'somethingNew' })) | Should -Be 'Not available'
        (Get-AdFlow ([pscustomobject]@{ enrollmentType = 'futureType' })).label | Should -Be 'Not available'
    }

    It 'excludes Not available records from success-rate inputs (improvements only count failures)' {
        $events = @([pscustomobject]@{ id = '1'; deploymentState = $null; enrollmentFailureDetails = 'Error 801C0003' })
        $m = ConvertTo-AdDeploymentModel -Dataset (New-Ds $events) -Rules $rules
        $m[0].status | Should -Be 'Not available'
        (Get-AdStructuralImprovements $m).Count | Should -Be 0
    }
}

Describe 'Deployment model' {
    It 'derives phase, flow, error codes, profile mismatch and findings from Graph data' {
        $ev = [pscustomobject]@{
            id = 'e1'; eventDateTime = '2026-10-20T10:00:00Z'; deploymentState = 'failure'; enrollmentType = 'azureADJoinedWithAutopilotProfile'
            deviceSetupStatus = 'failure'; deviceSerialNumber = 'SER1'; managedDeviceName = 'PC1'; userPrincipalName = 'a@contoso.example'
            deploymentTotalDuration = 'PT45M'; windowsAutopilotDeploymentProfileDisplayName = 'P1'
        }
        $pol = @{ e1 = @([pscustomobject]@{ displayName = 'VPN'; policyType = 'application'; complianceStatus = 'error'; errorCode = -2016345060; trackedOnEnrollmentStatus = $true }) }
        $ids = @([pscustomobject]@{ id = 'i1'; serialNumber = 'SER1'; manufacturer = 'HP'; model = 'EliteBook' })
        $prof = @{ i1 = [ordered]@{ deploymentProfile = [pscustomobject]@{ displayName = 'P1' }; intendedDeploymentProfile = [pscustomobject]@{ displayName = 'P2' } } }
        $m = ConvertTo-AdDeploymentModel -Dataset (New-Ds @($ev) $pol $ids $prof) -Rules $rules
        $d = $m[0]
        $d.phase | Should -Be 'ESP: device setup'
        $d.phaseSource | Should -Be 'graph'
        $d.flow | Should -Be 'User-driven (Entra join)'
        $d.errorCodes | Should -Contain '0x87D1041C'
        $d.model | Should -Be 'EliteBook'
        $d.profileMismatch | Should -BeTrue
        $d.durationSec | Should -Be 2700
        $d.findings.ruleId | Should -Contain 'ERR-87D1041C-DETECTION'
        $d.failedItems[0].name | Should -Be 'VPN'
    }

    It 'extracts error codes from free text without matching GUIDs' {
        $codes = Get-AdErrorCodesFromText 'Failed: 0x800705b4, also 80180018 and -2016345060; id 8d1f6a3e-2b4c-4e5f-9a0b-1c2d3e4f5a6b'
        $codes | Should -Contain '0x800705B4'
        $codes | Should -Contain '0x80180018'
        $codes | Should -Contain '0x87D1041C'
        $codes | Should -Not -Contain '0x8D1F6A3E'
    }

    It 'ranks structural improvements by impact' {
        $mk = { param($id, $text) [pscustomobject]@{ id = $id; deploymentState = 'failure'; enrollmentState = 'failed'; enrollmentFailureDetails = $text } }
        $events = @((& $mk 'a' 'Error 801C0003'), (& $mk 'b' 'Error 801C0003'), (& $mk 'c' 'Error 80180018'))
        $imp = Get-AdStructuralImprovements (ConvertTo-AdDeploymentModel -Dataset (New-Ds $events) -Rules $rules)
        $imp[0].ruleIds | Should -Contain 'ERR-801C0003'
        $imp[0].deployments | Should -Be 2
        $imp[0].rank | Should -Be 1
    }

    It 'builds the full demo data set' {
        $ds = New-AdDemoDataset -Count 60
        $m = ConvertTo-AdDeploymentModel -Dataset $ds -Rules $rules
        $m.Count | Should -Be 60
        @($m | Where-Object status -eq 'Failed').Count | Should -BeGreaterThan 0
        @($m | Where-Object { $_.serial -eq 'CTSDEMO0007' }).Count | Should -Be 1
    }
}

Describe 'Durations' {
    It 'parses ISO 8601 durations (<_.in>)' -ForEach @(@{ in = 'PT1H2M3S'; out = 3723 }, @{ in = 'P1DT1M'; out = 86460 }, @{ in = ''; out = $null }, @{ in = 'garbage'; out = $null }) {
        ConvertFrom-AdIsoDuration $_.in | Should -Be $_.out
    }
}
