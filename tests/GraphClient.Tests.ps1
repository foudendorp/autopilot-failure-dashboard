#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src\AutopilotDashboard.psm1') -Force
    $script:tp = { 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl' }
    function New-Resp([int]$Status, $Body, [hashtable]$Headers = @{}) {
        [pscustomobject]@{ StatusCode = $Status; Content = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 10 } else { '' }; Headers = $Headers }
    }
}

Describe 'Read-only enforcement' {
    It 'allows GET to Microsoft Graph' {
        (Test-AdGraphRequestAllowed -Method GET -Uri 'https://graph.microsoft.com/beta/deviceManagement/autopilotEvents').Allowed | Should -BeTrue
    }

    It 'blocks <_> to Microsoft Graph' -ForEach @('POST', 'PATCH', 'PUT', 'DELETE', 'MERGE') {
        (Test-AdGraphRequestAllowed -Method $_ -Uri 'https://graph.microsoft.com/beta/deviceManagement/managedDevices/00000000-0000-0000-0000-000000000000/wipe' -AllowDiagnosticsPost $true).Allowed | Should -BeFalse
    }

    It 'blocks other hosts, http, other ports and user info' -ForEach @(
        'https://evil.example/beta/x', 'http://graph.microsoft.com/beta/x', 'https://graph.microsoft.com:8443/beta/x',
        'https://user:pw@graph.microsoft.com/beta/x', 'https://graph.microsoft.com.evil.example/beta/x', '/beta/relative') {
        (Test-AdGraphRequestAllowed -Method GET -Uri $_).Allowed | Should -BeFalse
    }

    It 'allows only the documented createDownloadUrl POST, and only when enabled' {
        $u = 'https://graph.microsoft.com/beta/deviceManagement/managedDevices/5b7c0007-1111-4222-8333-000000000007/logCollectionRequests/abc_123/createDownloadUrl'
        (Test-AdGraphRequestAllowed -Method POST -Uri $u -AllowDiagnosticsPost $true).Allowed | Should -BeTrue
        (Test-AdGraphRequestAllowed -Method POST -Uri $u -AllowDiagnosticsPost $false).Allowed | Should -BeFalse
    }

    It 'blocks look-alike POST paths (<_>)' -ForEach @(
        'https://graph.microsoft.com/beta/deviceManagement/managedDevices/5b7c0007-1111-4222-8333-000000000007/createDeviceLogCollectionRequest',
        'https://graph.microsoft.com/beta/deviceManagement/managedDevices/5b7c0007-1111-4222-8333-000000000007/logCollectionRequests/abc/createDownloadUrl?x=1',
        'https://graph.microsoft.com/beta/deviceManagement/managedDevices/5b7c0007-1111-4222-8333-000000000007/logCollectionRequests/../wipe/createDownloadUrl',
        'https://graph.microsoft.com/beta/deviceManagement/managedDevices/5b7c0007-1111-4222-8333-000000000007/logCollectionRequests/a%2Fb/createDownloadUrl',
        'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/5b7c0007-1111-4222-8333-000000000007/logCollectionRequests/abc/createDownloadUrl',
        'https://graph.microsoft.com/beta/deviceManagement/managedDevices/not-a-guid/logCollectionRequests/abc/createDownloadUrl') {
        (Test-AdGraphRequestAllowed -Method POST -Uri $_ -AllowDiagnosticsPost $true).Allowed | Should -BeFalse
    }

    It 'throws before any network call when a write is attempted' {
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest { throw 'must not be called' }
        { Invoke-AdGraphRequest -Method DELETE -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/1' -TokenProvider $tp } | Should -Throw '*Read-only policy*'
        Should -Invoke -ModuleName AutopilotDashboard Invoke-WebRequest -Times 0 -Exactly
    }
}

Describe 'Pagination, throttling and errors' {
    BeforeEach { Mock -ModuleName AutopilotDashboard Start-Sleep { } }

    It 'follows @odata.nextLink until exhausted' {
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest {
            switch -Wildcard ($Uri) {
                '*skiptoken=2*' { New-Resp 200 @{ value = @(@{ id = 3 }); '@odata.nextLink' = 'https://graph.microsoft.com/beta/x?$skiptoken=3' } }
                '*skiptoken=3*' { New-Resp 200 @{ value = @(@{ id = 4 }, @{ id = 5 }) } }
                default { New-Resp 200 @{ value = @(@{ id = 1 }, @{ id = 2 }); '@odata.nextLink' = 'https://graph.microsoft.com/beta/x?$skiptoken=2' } }
            }
        }
        $items = Get-AdGraphCollection -Uri 'https://graph.microsoft.com/beta/x' -TokenProvider $tp
        $items.id | Should -Be @(1, 2, 3, 4, 5)
        Should -Invoke -ModuleName AutopilotDashboard Invoke-WebRequest -Times 3 -Exactly
    }

    It 'refuses a nextLink that points to another host (token never leaves Graph)' {
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest { New-Resp 200 @{ value = @(@{ id = 1 }); '@odata.nextLink' = 'https://evil.example/steal' } }
        { Get-AdGraphCollection -Uri 'https://graph.microsoft.com/beta/x' -TokenProvider $tp } | Should -Throw '*Read-only policy*'
        Should -Invoke -ModuleName AutopilotDashboard Invoke-WebRequest -Times 1 -Exactly
    }

    It 'handles an empty collection' {
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest { New-Resp 200 @{ value = @() } }
        @(Get-AdGraphCollection -Uri 'https://graph.microsoft.com/beta/x' -TokenProvider $tp).Count | Should -Be 0
    }

    It 'retries on 429 honouring Retry-After, then succeeds' {
        $script:calls = 0
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest {
            $script:calls++
            if ($script:calls -lt 3) { New-Resp 429 @{ error = @{ code = 'TooManyRequests'; message = 'slow down' } } @{ 'Retry-After' = @('7') } }
            else { New-Resp 200 @{ value = @(@{ id = 'ok' }) } }
        }
        $r = Invoke-AdGraphRequest -Uri 'https://graph.microsoft.com/beta/x' -TokenProvider $tp
        $r.value[0].id | Should -Be 'ok'
        Should -Invoke -ModuleName AutopilotDashboard Start-Sleep -Times 2 -Exactly -ParameterFilter { $Milliseconds -eq 7000 }
    }

    It 'gives up after MaxRetries on persistent 503' {
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest { New-Resp 503 @{ error = @{ code = 'ServiceUnavailable'; message = 'down' } } }
        { Invoke-AdGraphRequest -Uri 'https://graph.microsoft.com/beta/x' -TokenProvider $tp -MaxRetries 2 } | Should -Throw '*503*'
        Should -Invoke -ModuleName AutopilotDashboard Invoke-WebRequest -Times 3 -Exactly
    }

    It 'does not retry 403 and exposes the status' {
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest { New-Resp 403 @{ error = @{ code = 'Forbidden'; message = 'Application is not authorized' } } }
        try { Invoke-AdGraphRequest -Uri 'https://graph.microsoft.com/beta/x' -TokenProvider $tp; throw 'expected failure' }
        catch { $info = Get-AdGraphErrorInfo $_ }
        $info.status | Should -Be 403
        $info.code | Should -Be 'Forbidden'
        Should -Invoke -ModuleName AutopilotDashboard Invoke-WebRequest -Times 1 -Exactly
    }

    It 'sends the bearer token only in the Authorization header to Graph' {
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest { New-Resp 200 @{ value = @() } } -ParameterFilter { $Headers.Authorization -like 'Bearer eyJ*' -and ([uri]$Uri).Host -eq 'graph.microsoft.com' }
        $null = Invoke-AdGraphRequest -Uri 'https://graph.microsoft.com/beta/x' -TokenProvider $tp
        Should -Invoke -ModuleName AutopilotDashboard Invoke-WebRequest -Times 1 -Exactly
    }
}

Describe 'Data refresh resilience' {
    BeforeEach { Mock -ModuleName AutopilotDashboard Start-Sleep { } }

    It 'filters the date range locally (no server-side $filter) and reports 403 per source' {
        $now = [datetime]::UtcNow
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest {
            if ($Uri -match 'filter') { throw 'no server-side filter expected' }
            if ($Uri -like '*autopilotEvents') {
                return New-Resp 200 @{ value = @(
                        @{ id = 'in'; eventDateTime = $now.AddDays(-2).ToString('o'); deploymentState = 'success'; deviceSerialNumber = 'S1' },
                        @{ id = 'old'; eventDateTime = $now.AddDays(-200).ToString('o'); deploymentState = 'failure' }) }
            }
            return New-Resp 403 @{ error = @{ code = 'Forbidden'; message = 'no' } }
        }
        $cfg = Get-AdDefaultConfig
        $ds = Invoke-AdDataRefresh -TokenProvider $tp -Config $cfg -From $now.AddDays(-30) -To $now
        @($ds.events).id | Should -Be @('in')
        ($ds.sources | Where-Object name -eq 'Autopilot deployment events').message | Should -Match 'applied locally'
        ($ds.sources | Where-Object name -eq 'Autopilot registered devices').status | Should -Be 'forbidden'
        $ds.devicePrep.deploymentDataAvailable | Should -BeFalse
    }
}

Describe 'Policy status details retrieval' {
    BeforeEach {
        Mock -ModuleName AutopilotDashboard Start-Sleep { }
        $script:cfgTry = Get-AdDefaultConfig; $cfgTry.tryPolicyStatusDetails = $true
    }

    It 'does not call policyStatusDetails by default (removed from Graph beta)' {
        $now = [datetime]::UtcNow
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest {
            if ($Uri -like '*/autopilotEvents') { return New-Resp 200 @{ value = @(@{ id = 'autopilot_1'; eventDateTime = $now.AddDays(-1).ToString('o'); deploymentState = 'failure' }) } }
            return New-Resp 200 @{ value = @() }
        }
        $ds = Invoke-AdDataRefresh -TokenProvider $tp -Config (Get-AdDefaultConfig) -From $now.AddDays(-30) -To $now
        $src = $ds.sources | Where-Object name -eq 'Policy and app status per deployment'
        $src.status | Should -Be 'skipped'
        $src.message | Should -Match 'tryPolicyStatusDetails'
        Should -Invoke -ModuleName AutopilotDashboard Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like '*/policyStatusDetails' }
    }

    It 'stops after the first answer that the policyStatusDetails segment does not exist' {
        $now = [datetime]::UtcNow
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest {
            if ($Uri -like '*/policyStatusDetails') { return New-Resp 400 @{ error = @{ code = 'BadRequest'; message = "Resource not found for the segment 'policyStatusDetails'." } } }
            if ($Uri -like '*/autopilotEvents') {
                return New-Resp 200 @{ value = @(1..10 | ForEach-Object { @{ id = "autopilot_$_"; eventDateTime = $now.AddDays(-1).ToString('o'); deploymentState = 'failure' } }) }
            }
            return New-Resp 200 @{ value = @() }
        }
        $ds = Invoke-AdDataRefresh -TokenProvider $tp -Config $cfgTry -From $now.AddDays(-30) -To $now
        @($ds.events).Count | Should -Be 10
        $src = $ds.sources | Where-Object name -eq 'Policy and app status per deployment'
        $src.status | Should -Be 'unsupported'
        $src.message | Should -Match 'no longer exposes policyStatusDetails'
        Should -Invoke -ModuleName AutopilotDashboard Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*/policyStatusDetails' }
        Should -Invoke -ModuleName AutopilotDashboard Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like '*expand=policyStatusDetails*' }
    }

    It 'stops after 3 consecutive generic 400s' {
        $now = [datetime]::UtcNow
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest {
            if ($Uri -like '*/policyStatusDetails') { return New-Resp 400 @{ error = @{ code = 'BadRequest'; message = 'Something else' } } }
            if ($Uri -like '*/autopilotEvents') {
                return New-Resp 200 @{ value = @(1..10 | ForEach-Object { @{ id = "autopilot_$_"; eventDateTime = $now.AddDays(-1).ToString('o'); deploymentState = 'failure' } }) }
            }
            return New-Resp 200 @{ value = @() }
        }
        $ds = Invoke-AdDataRefresh -TokenProvider $tp -Config $cfgTry -From $now.AddDays(-30) -To $now
        ($ds.sources | Where-Object name -eq 'Policy and app status per deployment').message | Should -Match 'Stopped after 3 consecutive 400'
        Should -Invoke -ModuleName AutopilotDashboard Invoke-WebRequest -Times 3 -Exactly -ParameterFilter { $Uri -like '*/policyStatusDetails' }
    }

    It 'still uses policyStatusDetails where a tenant serves it' {
        $now = [datetime]::UtcNow
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest {
            if ($Uri -like '*/policyStatusDetails') { return New-Resp 200 @{ value = @(@{ displayName = 'VPN'; complianceStatus = 'error'; errorCode = -2016345060 }) } }
            if ($Uri -like '*/autopilotEvents') { return New-Resp 200 @{ value = @(@{ id = 'autopilot_1'; eventDateTime = $now.AddDays(-1).ToString('o'); deploymentState = 'failure' }) } }
            return New-Resp 200 @{ value = @() }
        }
        $ds = Invoke-AdDataRefresh -TokenProvider $tp -Config $cfgTry -From $now.AddDays(-30) -To $now
        @($ds.policyDetails['autopilot_1']).Count | Should -Be 1 -Because 'the items must not be nested in an extra array'
        $ds.policyDetails['autopilot_1'][0].displayName | Should -Be 'VPN'
        ($ds.sources | Where-Object name -eq 'Policy and app status per deployment').status | Should -Be 'ok'
    }
}

Describe 'Logging' {
    It 'includes the scrubbed Graph error message in the warning' {
        Mock -ModuleName AutopilotDashboard Start-Sleep { }
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest { New-Resp 400 @{ error = @{ code = 'BadRequest'; message = 'Bad segment for alex@contoso.example'; innerError = @{ 'request-id' = 'rid-1' } } } }
        $lines = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AutopilotDashboard Write-AdLog { $lines.Add((Protect-AdLogText $Message)) }
        { Invoke-AdGraphRequest -Uri 'https://graph.microsoft.com/beta/x' -TokenProvider $tp } | Should -Throw
        $lines[-1] | Should -Match 'Bad segment'
        $lines[-1] | Should -Match 'rid-1'
        $lines[-1] | Should -Not -Match 'alex@contoso'
    }

    It 'redacts tokens, authorization codes and UPNs' {
        $t = Protect-AdLogText 'Bearer eyJabcdefgh.eyJabcdefgh.sig code=0.AXYZ refresh_token=abc user alex@contoso.example'
        $t | Should -Not -Match 'eyJabcdefgh'
        $t | Should -Not -Match '0\.AXYZ'
        $t | Should -Not -Match 'alex@contoso'
        $t | Should -Not -Match 'refresh_token=abc'
    }
}
