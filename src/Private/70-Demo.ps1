# Demo mode: realistic, fully fictional Autopilot data (Contoso, *.contoso.example) in exactly the
# same shape as the Graph dataset, so the whole pipeline (analysis, charts, exports) is exercised.
# Dates are relative to "now" so the default 30-day range always has data.

function New-AdDemoDataset {
    [CmdletBinding()]
    param([int]$Seed = 4242, [int]$Days = 30, [int]$Count = 160, [datetime]$Now = [datetime]::UtcNow)

    $rnd = [System.Random]::new($Seed)
    $pick = { param($arr) $arr[$rnd.Next(0, $arr.Count)] }

    $first = 'Avery', 'Jordan', 'Riley', 'Morgan', 'Casey', 'Quinn', 'Rowan', 'Skyler', 'Emerson', 'Finley', 'Harper', 'Jamie', 'Kendall', 'Logan', 'Parker', 'Reese', 'Sawyer', 'Taylor', 'Dakota', 'Alex'
    $last = 'Kim', 'Novak', 'Okafor', 'Silva', 'Jansen', 'Moreau', 'Haddad', 'Lindqvist', 'Tanaka', 'Rossi', 'Kowalski', 'Mensah', 'Dubois', 'Fischer', 'Ortega', 'Visser'
    $models = @(
        @{ m = 'Dell Inc.'; n = 'Latitude 7440'; p = 'CTS' }, @{ m = 'HP'; n = 'EliteBook 840 G10'; p = 'CTS' },
        @{ m = 'LENOVO'; n = 'ThinkPad T14 Gen 4'; p = 'CTS' }, @{ m = 'Microsoft Corporation'; n = 'Surface Laptop 6'; p = 'CTS' },
        @{ m = 'Dell Inc.'; n = 'OptiPlex 7010'; p = 'KSK' }
    )
    $profiles = @{
        userDrivenEntra      = @{ id = '1d4f0c2a-0000-4000-8000-000000000001'; name = 'Contoso - User Driven (Entra)'; type = 'azureADJoinedWithAutopilotProfile' }
        userDrivenHybrid     = @{ id = '1d4f0c2a-0000-4000-8000-000000000002'; name = 'Contoso - User Driven (Hybrid)'; type = 'offlineDomainJoined' }
        selfDeploying        = @{ id = '1d4f0c2a-0000-4000-8000-000000000003'; name = 'Contoso - Kiosk Self-Deploying'; type = 'azureADJoinedUsingDeviceAuthWithAutopilotProfile' }
        preProvisionedEntra  = @{ id = '1d4f0c2a-0000-4000-8000-000000000004'; name = 'Contoso - Pre-Provisioned'; type = 'azureADJoinedWithWhiteGlove' }
    }
    $espName = 'Contoso ESP - Block until required apps'

    # Failure scenarios: weight, flow, phase fields, failure details, failing policy items
    $scenarios = @(
        @{ key = 'success'; w = 120 }
        @{ key = 'detection'; w = 7; flow = 'userDrivenEntra'; dev = 'failure'; items = @(@{ n = 'Contoso VPN Client 4.2'; t = 'application'; s = 'error'; c = -2016345060 }) }
        @{ key = 'anotherInstall'; w = 6; flow = 'userDrivenEntra'; dev = 'failure'; items = @(@{ n = 'Microsoft 365 Apps (MSI LOB)'; t = 'application'; s = 'error'; c = -2147023278 }, @{ n = 'Contoso Line-of-Business Tool'; t = 'application'; s = 'notInstalled'; c = 0 }) }
        @{ key = 'espTimeout'; w = 5; flow = 'userDrivenEntra'; dev = 'failure'; fail = 'ESP device setup did not complete before the timeout. HRESULT 0x800705b4'; items = @(@{ n = 'Adobe Acrobat Reader'; t = 'application'; s = 'notInstalled'; c = 0 }, @{ n = 'Contoso CAD Suite 2026'; t = 'application'; s = 'notInstalled'; c = 0 }) }
        @{ key = 'tpm'; w = 4; flow = 'selfDeploying'; enr = 'failed'; fail = 'Securing your hardware (Failed: 0x800705b4). Joining your organization''s network (Previous step failed).' }
        @{ key = 'hybrid'; w = 4; flow = 'userDrivenHybrid'; enr = 'failed'; fail = 'Something went wrong. Error code 80070774.' }
        @{ key = 'entraJoin'; w = 3; flow = 'userDrivenEntra'; enr = 'failed'; fail = 'Something went wrong. Error code 801C0003.' }
        @{ key = 'license'; w = 3; flow = 'userDrivenEntra'; enr = 'failed'; fail = 'Something went wrong. 80180018' }
        @{ key = 'reuse'; w = 2; flow = 'preProvisionedEntra'; enr = 'blocked'; fail = 'There was a problem. 0x80180014' }
        @{ key = 'certProfile'; w = 3; flow = 'userDrivenEntra'; acc = 'failure'; items = @(@{ n = 'Contoso Wi-Fi (SCEP)'; t = 'configurationPolicy'; s = 'error'; c = -2016281112 }) }
        @{ key = 'inProgress'; w = 2; flow = 'userDrivenEntra'; state = 'inProgress' }
        @{ key = 'missing'; w = 3 }
    )
    $totalWeight = ($scenarios | Measure-Object -Property w -Sum).Sum

    $events = [System.Collections.Generic.List[object]]::new()
    $identities = [System.Collections.Generic.List[object]]::new()
    $policyDetails = @{}
    $profilesByIdentity = @{}

    for ($i = 1; $i -le $Count; $i++) {
        $roll = $rnd.Next(0, $totalWeight); $acc = 0; $sc = $null
        foreach ($s in $scenarios) { $acc += $s.w; if ($roll -lt $acc) { $sc = $s; break } }
        # Pin the device used by the bundled sample diagnostics to the "anotherInstall" scenario.
        if ($i -eq 7) { $sc = $scenarios | Where-Object key -eq 'anotherInstall' }

        $flowKey = if ($sc.flow) { $sc.flow } elseif ($sc.key -eq 'success') { & $pick @('userDrivenEntra', 'userDrivenEntra', 'userDrivenEntra', 'userDrivenHybrid', 'preProvisionedEntra', 'selfDeploying') } else { 'userDrivenEntra' }
        $model = if ($flowKey -eq 'selfDeploying') { $models[4] } else { $models[$rnd.Next(0, 4)] }
        # Model skew: make one model over-represented in detection failures for the workshop story.
        if ($sc.key -eq 'detection' -and $rnd.Next(0, 3) -gt 0) { $model = $models[1] }
        $serial = if ($i -eq 7) { 'CTSDEMO0007' } else { 'CTS{0}{1:D4}' -f ([char](65 + $rnd.Next(0, 26))), $rnd.Next(1000, 9999) + $i }
        $fn = & $pick $first; $ln = & $pick $last
        $upn = if ($flowKey -eq 'selfDeploying') { $null } else { ('{0}.{1}@contoso.example' -f $fn, $ln).ToLowerInvariant() }
        $deviceName = '{0}-{1}' -f $model.p, $serial.Substring($serial.Length - 6)
        $start = $Now.AddDays(-$rnd.NextDouble() * ($Days - 0.5)).AddMinutes(-$rnd.Next(0, 600))
        $prof = $profiles[$flowKey]

        $identityId = '7a1e{0:D4}-0000-4000-8000-{1:D12}' -f $i, $i
        $identities.Add([pscustomobject]@{
                id = $identityId; serialNumber = $serial; manufacturer = $model.m; model = $model.n
                groupTag = if ($flowKey -eq 'selfDeploying') { 'Kiosk' } else { 'Standard' }
                deploymentProfileAssignmentStatus = 'assignedUnkownSyncState'; enrollmentState = 'enrolled'
            })
        $intended = $prof
        if ($rnd.Next(0, 25) -eq 0) { $intended = $profiles['userDrivenHybrid'] }   # occasional profile drift
        $profilesByIdentity[$identityId] = [ordered]@{
            deploymentProfile         = [pscustomobject]@{ id = $prof.id; displayName = $prof.name }
            intendedDeploymentProfile = [pscustomobject]@{ id = $intended.id; displayName = $intended.name }
        }

        $prep = $rnd.Next(120, 420); $devSetup = $rnd.Next(600, 2400); $accSetup = $rnd.Next(180, 900)
        $state = 'success'; $enrState = 'enrolled'; $devStatus = 'success'; $accStatus = 'success'; $failText = $null
        switch ($sc.key) {
            'success' { if ($rnd.Next(0, 12) -eq 0) { $state = 'successWithTimeout' } }
            'inProgress' { $state = 'inProgress'; $devStatus = 'inProgress'; $accStatus = 'notAttempted'; $accSetup = 0 }
            'missing' { $state = $null }
            default {
                $state = 'failure'
                if ($sc.enr) { $enrState = $sc.enr; $devStatus = 'notAttempted'; $accStatus = 'notAttempted'; $devSetup = 0; $accSetup = 0 }
                if ($sc.dev) { $devStatus = 'failure'; $accStatus = 'notAttempted'; $accSetup = 0; $devSetup = if ($sc.key -eq 'espTimeout') { 3600 } else { $rnd.Next(900, 2700) } }
                if ($sc.acc) { $accStatus = 'failure' }
                $failText = $sc.fail
            }
        }
        if ($flowKey -eq 'selfDeploying') { $accStatus = 'notAttempted'; $accSetup = 0 }
        $total = $prep + $devSetup + $accSetup
        $iso = { param($s) if ($s -gt 0) { [System.Xml.XmlConvert]::ToString([timespan]::FromSeconds($s)) } else { $null } }
        $eventId = 'e0a1{0:D4}-5a7b-4c1d-9e2f-{1:D12}' -f $i, ($i * 7)

        $ev = [ordered]@{
            id                                                       = $eventId
            eventDateTime                                            = $start.AddSeconds($total + 60).ToString('o')
            deviceRegisteredDateTime                                 = $start.AddDays(-$rnd.Next(2, 90)).ToString('o')
            enrollmentStartDateTime                                  = $start.AddSeconds($prep / 2).ToString('o')
            enrollmentType                                           = $prof.type
            deviceSerialNumber                                       = $serial
            managedDeviceName                                        = $deviceName
            userPrincipalName                                        = $upn
            windowsAutopilotDeploymentProfileDisplayName             = $prof.name
            enrollmentState                                          = $enrState
            windows10EnrollmentCompletionPageConfigurationDisplayName = $espName
            windows10EnrollmentCompletionPageConfigurationId         = 'c0ffee00-0000-4000-8000-000000000010'
            deploymentState                                          = $state
            deviceSetupStatus                                        = $devStatus
            accountSetupStatus                                       = $accStatus
            osVersion                                                = & $pick @('10.0.26100.6899', '10.0.26100.7171', '10.0.26200.7019')
            deploymentDuration                                       = & $iso $total
            deploymentTotalDuration                                  = & $iso ($total + 60)
            devicePreparationDuration                                = & $iso $prep
            deviceSetupDuration                                      = & $iso $devSetup
            accountSetupDuration                                     = & $iso $accSetup
            deploymentStartDateTime                                  = $start.ToString('o')
            deploymentEndDateTime                                    = if ($state -in 'inProgress', $null) { $null } else { $start.AddSeconds($total).ToString('o') }
            targetedAppCount                                         = $rnd.Next(6, 18)
            targetedPolicyCount                                      = $rnd.Next(12, 40)
            enrollmentFailureDetails                                 = $failText
            deviceId                                                 = if ($enrState -eq 'enrolled') { '5b7c{0:D4}-1111-4222-8333-{1:D12}' -f $i, $i } else { $null }
        }
        if ($sc.key -eq 'missing') {
            # Older/partial records: missing state, flow and duration -> must show as "Not available"
            foreach ($k in 'deploymentState', 'enrollmentType', 'deploymentDuration', 'deploymentTotalDuration', 'deviceSetupStatus', 'accountSetupStatus') { $ev[$k] = $null }
        }
        $events.Add([pscustomobject]$ev)

        if ($state -ne 'success' -and $state -ne 'successOnRetry') {
            $items = [System.Collections.Generic.List[object]]::new()
            foreach ($it in @($sc.items)) {
                if (-not $it) { continue }
                $items.Add([pscustomobject]@{
                        id = [guid]::new($rnd.Next(), 0, 0, [byte[]](1, 2, 3, 4, 5, 6, 7, 8)).ToString(); displayName = $it.n; policyType = $it.t
                        complianceStatus = $it.s; trackedOnEnrollmentStatus = $true; lastReportedDateTime = $start.AddSeconds($prep + $devSetup - 30).ToString('o'); errorCode = $it.c
                    })
            }
            foreach ($ok in 'Contoso Baseline - Device Restrictions', 'Microsoft Edge', 'Company Portal') {
                $items.Add([pscustomobject]@{
                        id = [guid]::new($rnd.Next(), 0, 0, [byte[]](9, 9, 9, 9, 9, 9, 9, 9)).ToString(); displayName = $ok
                        policyType = if ($ok -like 'Contoso*') { 'configurationPolicy' } else { 'application' }
                        complianceStatus = if ($ok -like 'Contoso*') { 'compliant' } else { 'installed' }; trackedOnEnrollmentStatus = ($ok -ne 'Microsoft Edge'); lastReportedDateTime = $start.AddSeconds($prep + 300).ToString('o'); errorCode = 0
                    })
            }
            $policyDetails[$eventId] = $items.ToArray()
        }
    }

    $sources = @(
        [ordered]@{ name = 'Autopilot deployment events'; endpoint = '/beta/deviceManagement/autopilotEvents'; beta = $true; status = 'demo'; count = $events.Count; message = 'Fictional demo data.' }
        [ordered]@{ name = 'Policy and app status per deployment'; endpoint = '/beta/deviceManagement/autopilotEvents/{id}/policyStatusDetails'; beta = $true; status = 'demo'; count = $policyDetails.Count; message = 'Fictional demo data.' }
        [ordered]@{ name = 'Autopilot registered devices'; endpoint = '/beta/deviceManagement/windowsAutopilotDeviceIdentities'; beta = $true; status = 'demo'; count = $identities.Count; message = 'Fictional demo data.' }
        [ordered]@{ name = 'Deployment and intended deployment profile per device'; endpoint = '/beta/deviceManagement/windowsAutopilotDeviceIdentities/{id}?$expand=deploymentProfile,intendedDeploymentProfile'; beta = $true; status = 'demo'; count = $profilesByIdentity.Count; message = 'Fictional demo data.' }
        [ordered]@{ name = 'Autopilot device preparation policies'; endpoint = '/beta/deviceManagement/configurationPolicies (filtered locally)'; beta = $true; status = 'demo'; count = 1; message = 'Fictional demo data.' }
    )
    return [ordered]@{
        mode          = 'demo'
        refreshedUtc  = $Now.ToString('o')
        from          = $Now.AddDays(-$Days).ToString('o')
        to            = $Now.ToString('o')
        events        = $events.ToArray()
        policyDetails = $policyDetails
        identities    = $identities.ToArray()
        profiles      = $profilesByIdentity
        devicePrep    = [ordered]@{
            deploymentDataAvailable = $false
            deploymentDataMessage   = 'Not available in demo mode, and not retrieved in tenant mode: device preparation deployment status is only exposed through POST /beta/deviceManagement/reports/exportJobs, which is outside the read-only policy.'
            policies                = @([ordered]@{ id = 'dp000000-0000-4000-8000-000000000001'; name = 'Contoso - Device Preparation (Windows 11)'; lastModified = $Now.AddDays(-12).ToString('o') })
        }
        sources       = $sources
        rawEvents     = $events.ToArray()
        stats         = New-AdPipelineStats -Selection (Select-AdEventsInRange -Events $events.ToArray() -From $Now.AddDays(-$Days) -To $Now.AddHours(1)) -Pages 1 -Endpoint 'Demo data (fictional)'
    }
}

function New-AdDemoDiagnosticsArchive {
    <# Zips the bundled fictional sample diagnostics folder into a temp .zip for analysis. #>
    param([Parameter(Mandatory)][string]$SampleFolder)
    $zip = Join-Path (New-AdTempFolder) 'Contoso-sample-diagnostics.zip'
    Compress-Archive -Path (Join-Path $SampleFolder '*') -DestinationPath $zip
    return $zip
}
