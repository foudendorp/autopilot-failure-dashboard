#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Regression: a real failed deployment that the Intune portal and the unfiltered Graph call show,
# but the dashboard did not. Graph's server-side $filter on eventDateTime dropped it, and the local
# and frontend date filters looked at eventDateTime only.
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src\AutopilotDashboard.psm1') -Force
    $script:rules = Import-AdRules -Path (Join-Path $root 'rules.json')
    $script:tp = { 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl' }
    function New-Resp([int]$Status, $Body) { [pscustomobject]@{ StatusCode = $Status; Content = ($Body | ConvertTo-Json -Depth 10); Headers = @{} } }

    $script:now = [datetime]::new(2026, 11, 6, 12, 0, 0, [DateTimeKind]::Utc)
    $script:from = $now.AddDays(-14).Date
    $script:to = $now.Date.AddDays(1).AddSeconds(-1)
    # The example: deploymentState Failure, deployment started inside the range, but no usable
    # eventDateTime (Graph returns 0001-01-01 / null), so `eventDateTime ge ...` excludes it server-side.
    $script:failedExample = [ordered]@{
        id = 'autopilot_11111111-0000-0000-0000-000000000001'; deploymentState = 'failure'
        eventDateTime = '0001-01-01T00:00:00Z'; deploymentStartDateTime = $now.AddDays(-3).ToString('o')
        enrollmentStartDateTime = $now.AddDays(-3).AddMinutes(5).ToString('o'); deviceSerialNumber = 'SN-EXAMPLE-1'
        managedDeviceName = 'PC-EXAMPLE'; userPrincipalName = 'someone@contoso.example'; enrollmentType = 'azureADJoinedWithAutopilotProfile'
        deviceSetupStatus = 'failure'; enrollmentState = 'enrolled'
    }
    # Variant: eventDateTime set, but outside the range, while the deployment started inside it.
    $script:failedLateEvent = [ordered]@{
        id = 'autopilot_11111111-0000-0000-0000-000000000002'; deploymentState = 'Failure'
        eventDateTime = $now.AddDays(-40).ToString('o'); deploymentStartDateTime = $now.AddDays(-2).ToString('o')
        deviceSerialNumber = 'SN-EXAMPLE-2'; managedDeviceName = 'PC-EXAMPLE-2'
    }
    $script:normal = [ordered]@{ id = 'autopilot_ok'; deploymentState = 'success'; eventDateTime = $now.AddDays(-1).ToString('o'); deviceSerialNumber = 'SN-OK' }
    $script:old = [ordered]@{ id = 'autopilot_old'; deploymentState = 'failure'; eventDateTime = $now.AddDays(-60).ToString('o'); deploymentStartDateTime = $now.AddDays(-60).ToString('o') }

    function Invoke-ExampleRefresh {
        Mock -ModuleName AutopilotDashboard Start-Sleep { }
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest {
            if ($Uri -match 'autopilotEvents\?.*filter') {
                # What Graph does with `eventDateTime ge/le`: rows without a matching eventDateTime are gone.
                return New-Resp 200 @{ value = @($normal) }
            }
            if ($Uri -match 'autopilotEvents\?\$skiptoken=2') { return New-Resp 200 @{ value = @($old, $failedLateEvent) } }
            if ($Uri -match '/autopilotEvents$') {
                return New-Resp 200 @{ value = @($normal, $failedExample); '@odata.nextLink' = 'https://graph.microsoft.com/beta/deviceManagement/autopilotEvents?$skiptoken=2' }
            }
            return New-Resp 200 @{ value = @() }
        }
        Invoke-AdDataRefresh -TokenProvider $tp -Config (Get-AdDefaultConfig) -From $from -To $to
    }
}

Describe 'Regression: failed deployment missing from the dashboard' {
    BeforeAll { $script:ds = Invoke-ExampleRefresh }

    It 'retrieves the failed deployment (no server-side eventDateTime filter, all pages followed)' {
        @($ds.events).id | Should -Contain $failedExample.id
        @($ds.events).id | Should -Contain $failedLateEvent.id
        Should -Invoke -ModuleName AutopilotDashboard Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -match 'filter' }
    }

    It 'keeps rows whose deployment started in range and drops rows that are entirely outside it' {
        @($ds.events).id | Should -Not -Contain 'autopilot_old'
        $ds.stats.rawRows | Should -Be 4
        $ds.stats.pages | Should -Be 2
        $ds.stats.excludedByDate | Should -Be 1
        $ds.stats.keptRows | Should -Be 3
    }

    It 'translates the status to Failed and dates it by deployment start' {
        $m = ConvertTo-AdDeploymentModel -Dataset $ds -Rules $rules
        $d = $m | Where-Object id -eq $failedExample.id
        $d.status | Should -Be 'Failed'
        $d.day | Should -Be $now.AddDays(-3).ToString('yyyy-MM-dd')
        $d.dayCandidates | Should -Contain $now.AddDays(-3).ToString('yyyy-MM-dd')
        ($m | Where-Object id -eq $failedLateEvent.id).status | Should -Be 'Failed'
    }

    It 'records the raw deploymentState values as received, with their mapping' {
        $ds.stats.rawDeploymentStates['failure'] | Should -Be 2
        $ds.stats.rawDeploymentStates['Failure'] | Should -Be 1
    }
}

Describe 'Status translation' {
    It "maps '<_>' to Failed" -ForEach @('failure', 'Failure', 'FAILURE', ' failure ', 'failed') {
        Get-AdStatus ([pscustomobject]@{ deploymentState = $_ }) | Should -Be 'Failed'
    }
    It "maps '<_>' to Success" -ForEach @('success', 'SuccessWithTimeout', 'successOnRetry') {
        Get-AdStatus ([pscustomobject]@{ deploymentState = $_ }) | Should -Be 'Success'
    }
    It 'keeps unknown values as Not available (never counted as success or failure)' {
        Get-AdStatus ([pscustomobject]@{ deploymentState = 'somethingNew' }) | Should -Be 'Not available'
        Get-AdStatus ([pscustomobject]@{ deploymentState = $null }) | Should -Be 'Not available'
    }
}

Describe 'Pipeline diagnostics' {
    BeforeAll {
        $script:state = New-AdAppState -Config (Get-AdDefaultConfig) -RootPath $root -Rules $rules
        $state.Auth.Status = 'signedIn'
        $state.Auth.AccessToken = 'eyJSECRETACCESS.eyJ.sig'
        $state.Auth.RefreshToken = 'SECRET-REFRESH'
        $state.Auth.Account = [ordered]@{ name = 'Admin Person'; upn = 'admin@contoso.example'; tenantId = '33333333-3333-3333-3333-333333333333'; domain = 'contoso.example' }
        $state.Auth.GrantedScopes = 'https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All openid profile'
        $state.Dataset = Invoke-ExampleRefresh
        Update-AdModel -AppState $state
        $script:diag = Get-AdPipelineDiagnostics -AppState $state
        $script:json = $diag | ConvertTo-Json -Depth 20
    }

    It 'reports raw, processed and status counts' {
        $diag.graph.rawRows | Should -Be 4
        $diag.graph.excludedByDate | Should -Be 1
        $diag.processing.modelRows | Should -Be 3
        ($diag.processing.statusCounts | Where-Object status -eq 'Failed').count | Should -Be 2
        @($diag.processing.rawStates | Where-Object { $_.raw -ceq 'Failure' }).Count | Should -Be 1 -Because 'raw values keep their original casing'
        ($diag.processing.rawStates | Where-Object { $_.raw -ceq 'Failure' }).mappedTo | Should -Be 'Failed'
    }

    It 'reports tenant and missing scopes' {
        $diag.auth.tenantId | Should -Be '33333333-3333-3333-3333-333333333333'
        $diag.auth.missingScopes | Should -Contain 'https://graph.microsoft.com/DeviceManagementServiceConfig.Read.All'
    }

    It 'never contains tokens or personal data' {
        $json | Should -Not -Match 'eyJ|SECRET'
        $json | Should -Not -Match '@contoso\.example|Admin Person|PC-EXAMPLE|SN-EXAMPLE'
    }

    It 'explains where a specific deployment is, without returning personal data' {
        $r = Find-AdPipelineRow -AppState $state -Query 'sn-example-1'
        $r.matches.Count | Should -Be 1
        $r.matches[0].verdict | Should -Be 'shown'
        $r.matches[0].mappedStatus | Should -Be 'Failed'
        $r.matches[0].rawDeploymentState | Should -Be 'failure'
        $old = Find-AdPipelineRow -AppState $state -Query 'autopilot_old'
        $old.matches[0].verdict | Should -Be 'outsideRange'
        ($r | ConvertTo-Json -Depth 10) | Should -Not -Match 'PC-EXAMPLE|someone@'
    }
}

Describe 'Regression: tenant with exactly one deployment showed an empty list' {
    # PowerShell unrolls a one-item list in `x = if (...) { $list }`, so the browser received
    # "deployments": { ... } instead of [ { ... } ] and the table stayed empty.
    BeforeAll {
        function New-OneRowState([object[]]$Events) {
            $s = New-AdAppState -Config (Get-AdDefaultConfig) -RootPath $root -Rules $rules
            $s.Dataset = [ordered]@{ mode = 'tenant'; refreshedUtc = $now.ToString('o'); from = $from.ToString('o'); to = $to.ToString('o')
                events = $Events; rawEvents = $Events; policyDetails = @{}; identities = @(); profiles = @{}; sources = @(); devicePrep = $null
                stats = New-AdPipelineStats -Selection (Select-AdEventsInRange -Events $Events -From $from -To $to) -Pages 1 -Endpoint 'test' }
            Update-AdModel -AppState $s
            return $s
        }
    }

    It 'sends deployments and improvements as JSON arrays when there is one deployment (anonymize <_>)' -ForEach @($false, $true) {
        # With an error code, so there is exactly one finding and one structural improvement too.
        $one = [ordered]@{} + $failedExample; $one.enrollmentFailureDetails = 'Something went wrong. Error code 801C0003.'
        $s = New-OneRowState @([pscustomobject]$one)
        $s.Anonymize = $_
        $json = Get-AdDataJson -AppState $s
        $json | Should -Match '"deployments":\[\{'
        $json | Should -Match '"improvements":\[\{'
        $json | Should -Match '"sources":\['
        (($json | ConvertFrom-Json -NoEnumerate).deployments).Count | Should -Be 1
    }

    It 'sends an empty array when there are no deployments' {
        $s = New-OneRowState @()
        Get-AdDataJson -AppState $s | Should -Match '"deployments":\[\]'
    }

    It 'pipeline diagnostics count one row, not the fields of that row' {
        $s = New-OneRowState @([pscustomobject]$failedExample)
        (Get-AdPipelineDiagnostics -AppState $s).processing.modelRows | Should -Be 1
    }
}

Describe 'Frontend filters (node)' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
    It 'passes the JavaScript filter tests' {
        $out = & node --test (Join-Path $PSScriptRoot 'js\filters.test.mjs') 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
    }
}
