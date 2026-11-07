# Analysis engine: turns raw Graph data (+ optional parsed logs) into deployment models with
# phase, evidence, rule-based findings and a ranked list of structural improvements.
# Rules live in rules.json; nothing here is specific to a single error code.

$script:AdPhases = @(
    'Registration and profile', 'OOBE and network', 'Entra join and MDM enrollment',
    'ESP: device preparation', 'ESP: device setup', 'ESP: account setup', 'Not available'
)
$script:AdConfidenceWeight = @{ high = 3; medium = 2; low = 1 }

function Get-AdPhaseNames { $script:AdPhases }

function Import-AdRules {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20
    $rules = @($doc.rules)
    $required = 'id', 'phase', 'signal', 'likelyCause', 'recommendedFix', 'structuralAction', 'confidence', 'sourceUrl'
    $seen = @{}
    foreach ($r in $rules) {
        foreach ($f in $required) {
            if (-not $r.PSObject.Properties[$f] -or [string]::IsNullOrWhiteSpace([string]$r.$f)) { throw "Rule '$($r.id)' is missing required field '$f'." }
        }
        if ($seen.ContainsKey($r.id)) { throw "Duplicate rule id '$($r.id)'." }
        $seen[$r.id] = $true
        if ($r.confidence -notin 'high', 'medium', 'low') { throw "Rule '$($r.id)' has invalid confidence '$($r.confidence)'." }
        if ($r.phase -notin $script:AdPhases) { throw "Rule '$($r.id)' has unknown phase '$($r.phase)'." }
        if ($r.sourceUrl -notmatch '^https://learn\.microsoft\.com/') { throw "Rule '$($r.id)' sourceUrl must be a https://learn.microsoft.com/ URL." }
        $t = [string]$r.signal.type
        switch ($t) {
            'eventId' { if (-not $r.signal.values) { throw "Rule '$($r.id)': eventId signal needs values." } }
            'errorCode' {
                if (-not $r.signal.values) { throw "Rule '$($r.id)': errorCode signal needs values." }
                foreach ($v in $r.signal.values) { if (-not (ConvertTo-AdHexCode $v)) { throw "Rule '$($r.id)': invalid error code '$v'." } }
            }
            'registryValue' { if (-not $r.signal.name -or $null -eq $r.signal.equals) { throw "Rule '$($r.id)': registryValue signal needs name and equals." } }
            'text' { if (-not $r.signal.pattern) { throw "Rule '$($r.id)': text signal needs pattern." }; $null = [regex]::new($r.signal.pattern) }
            'espInstallationState' { if ($null -eq $r.signal.equals) { throw "Rule '$($r.id)': espInstallationState signal needs equals." } }
            'policyStatus' { if (-not $r.signal.equals) { throw "Rule '$($r.id)': policyStatus signal needs equals." } }
            default { throw "Rule '$($r.id)' has unknown signal type '$t'." }
        }
    }
    return $rules
}

function ConvertTo-AdHexCode {
    <# Normalises an error code (int, negative int, "0x...", bare hex, decimal string) to "0xXXXXXXXX". #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int64] -or $Value -is [uint32]) {
        $n = [long]$Value
        if ($n -eq 0) { return $null }
        if ($n -lt 0) { $n = $n + 4294967296 }
        if ($n -gt 4294967295) { return $null }
        return ('0x{0:X8}' -f [uint32]$n)
    }
    $s = ([string]$Value).Trim()
    if ($s -match '^(?i)0x([0-9a-f]{1,8})$') { return ('0x{0}' -f $Matches[1].ToUpperInvariant().PadLeft(8, '0')) }
    if ($s -match '^(?i)[0-9a-f]{8}$' -and $s -match '[a-fA-F]|^8') { return ('0x' + $s.ToUpperInvariant()) }
    $l = 0L
    if ([long]::TryParse($s, [ref]$l)) { return ConvertTo-AdHexCode ([long]$l) }
    return $null
}

function Get-AdErrorCodesFromText {
    param([AllowNull()][string]$Text)
    $codes = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return , @() }
    foreach ($m in [regex]::Matches($Text, '(?i)(?<![0-9a-z\-])(?:0x)?([8C][0-9a-f]{7})(?![0-9a-z\-])')) {
        $c = ConvertTo-AdHexCode ('0x' + $m.Groups[1].Value)
        if ($c -and -not $codes.Contains($c)) { $codes.Add($c) }
    }
    foreach ($m in [regex]::Matches($Text, '(?<![0-9])-2\d{9}(?![0-9])')) {
        $c = ConvertTo-AdHexCode $m.Value
        if ($c -and -not $codes.Contains($c)) { $codes.Add($c) }
    }
    return , $codes.ToArray()
}

function ConvertFrom-AdIsoDuration {
    param($Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try {
        $ts = [System.Xml.XmlConvert]::ToTimeSpan([string]$Value)
        if ($ts.TotalSeconds -le 0) { return $null }
        return [int]$ts.TotalSeconds
    }
    catch { return $null }
}

function Get-AdFlow {
    param($Event)
    $et = [string](Get-AdProp $Event 'enrollmentType')
    $map = @{
        'azureADJoinedWithAutopilotProfile'                   = @('userDrivenEntra', 'User-driven (Entra join)', @('userDriven', 'entra'))
        'offlineDomainJoined'                                 = @('userDrivenHybrid', 'User-driven (hybrid join)', @('userDriven', 'hybrid'))
        'azureADJoinedUsingDeviceAuthWithAutopilotProfile'    = @('selfDeploying', 'Self-deploying', @('selfDeploying', 'entra'))
        'azureADJoinedUsingDeviceAuthWithoutAutopilotProfile' = @('selfDeploying', 'Self-deploying', @('selfDeploying', 'entra'))
        'azureADJoinedWithWhiteGlove'                         = @('preProvisionedEntra', 'Pre-provisioned (Entra join)', @('preProvisioned', 'entra'))
        'offlineDomainJoinedWithWhiteGlove'                   = @('preProvisionedHybrid', 'Pre-provisioned (hybrid join)', @('preProvisioned', 'hybrid'))
        'azureADJoinedWithOfflineAutopilotProfile'            = @('userDrivenEntra', 'User-driven (Entra join, offline profile)', @('userDriven', 'entra'))
        'offlineDomainJoinedWithOfflineAutopilotProfile'      = @('userDrivenHybrid', 'User-driven (hybrid join, offline profile)', @('userDriven', 'hybrid'))
        'devicePreparation'                                   = @('devicePreparation', 'Device preparation', @('devicePreparation', 'entra'))
    }
    if ($et -and $map.ContainsKey($et)) {
        $v = $map[$et]
        return [ordered]@{ key = $v[0]; label = $v[1]; tags = $v[2] }
    }
    return [ordered]@{ key = 'notAvailable'; label = 'Not available'; tags = @() }
}

function Get-AdStatus {
    <# Maps deploymentState to a dashboard status. Explicitly case- and whitespace-insensitive; 'failed'
       is accepted too (it is the enrollmentState spelling). Unknown values are "Not available". #>
    param($Event)
    $raw = ([string](Get-AdProp $Event 'deploymentState')).Trim().ToLowerInvariant()
    switch -Exact ($raw) {
        { $_ -in 'success', 'successwithtimeout', 'successonretry' } { return 'Success' }
        { $_ -in 'failure', 'failed' } { return 'Failed' }
        'inprogress' { return 'In progress' }
        { $_ -in 'notattempted', 'disabled' } { return 'Not attempted' }
        default { return 'Not available' }
    }
}

function Get-AdDeploymentDate {
    <# The date shown for a deployment: when it started (as in the Intune portal), else the first known date. #>
    param($Event)
    @(Get-AdEventDates $Event) | Select-Object -First 1
}

function Get-AdGraphPhase {
    <# Phase derived from Graph status fields only. Returns $null when Graph does not say. #>
    param($Event)
    $enr = [string](Get-AdProp $Event 'enrollmentState')
    $dev = [string](Get-AdProp $Event 'deviceSetupStatus')
    $acc = [string](Get-AdProp $Event 'accountSetupStatus')
    $fail = [string](Get-AdProp $Event 'enrollmentFailureDetails')
    if ($enr -in 'failed', 'blocked') { return 'Entra join and MDM enrollment' }
    if ($dev -eq 'failure') { return 'ESP: device setup' }
    if ($acc -eq 'failure') { return 'ESP: account setup' }
    if ($fail -and $dev -in '', 'unknown', 'notAttempted') { return 'Entra join and MDM enrollment' }
    return $null
}

function New-AdEvidence {
    param([string]$Source, [string]$Kind, [string]$Key, $Value, [string]$Detail, $Time)
    [ordered]@{
        source = $Source; kind = $Kind; key = $Key; value = $Value; detail = $Detail
        time   = if ($Time) { ([datetime]$Time).ToUniversalTime().ToString('o') } else { $null }
    }
}

function Get-AdGraphEvidence {
    param($Event, $PolicyDetails)
    $ev = [System.Collections.Generic.List[object]]::new()
    $fail = [string](Get-AdProp $Event 'enrollmentFailureDetails')
    if ($fail) {
        $ev.Add((New-AdEvidence 'Graph: autopilotEvent' 'text' 'enrollmentFailureDetails' $fail 'Enrollment failure details reported by Intune' $null))
        foreach ($c in (Get-AdErrorCodesFromText $fail)) {
            $ev.Add((New-AdEvidence 'Graph: autopilotEvent' 'errorCode' 'enrollmentFailureDetails' $c "Error code found in enrollment failure details" $null))
        }
    }
    foreach ($field in 'deploymentState', 'enrollmentState', 'deviceSetupStatus', 'accountSetupStatus') {
        $v = [string](Get-AdProp $Event $field)
        if ($v -in 'failure', 'failed', 'blocked', 'successWithTimeout') {
            $ev.Add((New-AdEvidence 'Graph: autopilotEvent' 'status' $field $v "$field = $v" $null))
        }
    }
    foreach ($p in @($PolicyDetails)) {
        if ($null -eq $p) { continue }
        $status = [string](Get-AdProp $p 'complianceStatus')
        $name = [string](Get-AdProp $p 'displayName')
        $code = ConvertTo-AdHexCode (Get-AdProp $p 'errorCode')
        $tracked = [bool](Get-AdProp $p 'trackedOnEnrollmentStatus')
        if ($status -in 'error', 'notCompliant') {
            $ev.Add((New-AdEvidence 'Graph: policyStatusDetails' 'policyStatus' $name $status ("{0} '{1}' reported {2}{3}" -f (Get-AdProp $p 'policyType'), $name, $status, $(if ($tracked) { ' (tracked by ESP)' } else { '' })) (Get-AdDateValue (Get-AdProp $p 'lastReportedDateTime'))))
        }
        if ($code) {
            $ev.Add((New-AdEvidence 'Graph: policyStatusDetails' 'errorCode' $name $code "Error code on '$name'" (Get-AdDateValue (Get-AdProp $p 'lastReportedDateTime'))))
        }
    }
    return , $ev.ToArray()
}

function Get-AdLogEvidence {
    param($LogAnalysis)
    $ev = [System.Collections.Generic.List[object]]::new()
    $src = "Log: $($LogAnalysis.fileName)"
    $reg = $LogAnalysis.autopilotRegistry
    if ($reg) {
        foreach ($k in @($reg.Keys)) {
            if ($null -ne $reg[$k] -and $k -in 'TenantMatched', 'IsAutopilotDisabled', 'CloudAssignedTenantDomain', 'CloudAssignedTenantId', 'AadTenantId') {
                $ev.Add((New-AdEvidence $src 'registryValue' $k $reg[$k] "HKLM\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot\$k = $($reg[$k])" $null))
            }
        }
    }
    foreach ($e in @($LogAnalysis.espTracking)) {
        if ($null -eq $e) { continue }
        $ev.Add((New-AdEvidence $src 'espInstallationState' $e.item $e.installationState "$($e.scope): $($e.item) InstallationState = $($e.installationState) ($($e.stateName))" $null))
    }
    foreach ($e in @($LogAnalysis.autopilotEvents)) {
        if ($null -eq $e) { continue }
        $ev.Add((New-AdEvidence $src 'eventId' "Event $($e.id)" ([int]$e.id) $e.message $e.time))
        foreach ($c in (Get-AdErrorCodesFromText $e.message)) { $ev.Add((New-AdEvidence $src 'errorCode' "Event $($e.id)" $c "Error code in Autopilot event $($e.id)" $e.time)) }
    }
    foreach ($t in @($LogAnalysis.textSignals)) {
        if ($null -eq $t) { continue }
        $ev.Add((New-AdEvidence $src 'text' "$($t.file):$($t.line)" $t.text "Log line $($t.file):$($t.line)" $null))
        foreach ($c in (Get-AdErrorCodesFromText $t.text)) { $ev.Add((New-AdEvidence $src 'errorCode' "$($t.file):$($t.line)" $c "Error code in $($t.file):$($t.line)" $null)) }
    }
    return , $ev.ToArray()
}

function Test-AdRuleSignal {
    param($Rule, $Evidence)
    $s = $Rule.signal
    switch ([string]$s.type) {
        'eventId' { return ($Evidence.kind -eq 'eventId' -and [int]$Evidence.value -in @($s.values | ForEach-Object { [int]$_ })) }
        'errorCode' {
            if ($Evidence.kind -ne 'errorCode') { return $false }
            $codes = @($s.values | ForEach-Object { ConvertTo-AdHexCode $_ })
            return ([string]$Evidence.value -in $codes)
        }
        'registryValue' {
            if ($Evidence.kind -ne 'registryValue' -or $Evidence.key -ne $s.name) { return $false }
            return ([string]$Evidence.value -eq [string]$s.equals)
        }
        'text' { return ($Evidence.kind -eq 'text' -and [string]$Evidence.value -match $s.pattern) }
        'espInstallationState' { return ($Evidence.kind -eq 'espInstallationState' -and [string]$Evidence.value -eq [string]$s.equals) }
        'policyStatus' { return ($Evidence.kind -eq 'policyStatus' -and [string]$Evidence.value -eq [string]$s.equals) }
    }
    return $false
}

function Test-AdRuleContext {
    <# Returns 'match', 'unknown' (context can't be determined) or 'mismatch'. #>
    param($Rule, [string[]]$FlowTags, [string]$GraphPhase)
    $ctx = if ($Rule.PSObject.Properties['context']) { $Rule.context } else { $null }
    if (-not $ctx) { return 'none' }
    $result = 'match'
    if ($ctx.PSObject.Properties['flowTags'] -and $ctx.flowTags) {
        if (-not $FlowTags -or $FlowTags.Count -eq 0) { $result = 'unknown' }
        elseif (-not ($FlowTags | Where-Object { $_ -in $ctx.flowTags })) { return 'mismatch' }
    }
    if ($ctx.PSObject.Properties['phases'] -and $ctx.phases) {
        if (-not $GraphPhase) { $result = 'unknown' }
        elseif ($GraphPhase -notin $ctx.phases) { return 'mismatch' }
    }
    return $result
}

function Find-AdRuleMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence,
        [Parameter(Mandatory)][object[]]$Rules,
        [string[]]$FlowTags = @(),
        [string]$GraphPhase
    )
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($rule in $Rules) {
        $hits = @($Evidence | Where-Object { Test-AdRuleSignal $rule $_ })
        if (-not $hits) { continue }
        $ctx = Test-AdRuleContext -Rule $rule -FlowTags $FlowTags -GraphPhase $GraphPhase
        if ($ctx -eq 'mismatch') { continue }
        $score = $script:AdConfidenceWeight[[string]$rule.confidence]
        if ($ctx -eq 'match') { $score += 1 }
        $generic = [bool]($rule.PSObject.Properties['generic'] -and $rule.generic)
        if ($generic) { $score -= 1.5 }   # catch-all rules rank below specific explanations
        $findings.Add([ordered]@{
                ruleId           = $rule.id
                phase            = $rule.phase
                signal           = if ($rule.signal.PSObject.Properties['description']) { $rule.signal.description } else { $rule.signal.type }
                signalKey        = ('{0}:{1}' -f $rule.signal.type, (($rule.signal | ConvertTo-Json -Compress -Depth 5)))
                likelyCause      = $rule.likelyCause
                recommendedFix   = $rule.recommendedFix
                structuralAction = $rule.structuralAction
                confidence       = $rule.confidence
                sourceUrl        = $rule.sourceUrl
                contextMatch     = $ctx
                generic          = $generic
                ambiguous        = $false
                label            = ''
                score            = $score
                evidence         = $hits
            })
    }
    # A signal is ambiguous when more than one rule explains the same piece of evidence.
    $byEvidence = @{}
    foreach ($f in $findings) {
        foreach ($e in $f.evidence) {
            $k = "$($e.source)|$($e.kind)|$($e.key)|$($e.value)"
            if (-not $byEvidence.ContainsKey($k)) { $byEvidence[$k] = [System.Collections.Generic.List[object]]::new() }
            if (-not $byEvidence[$k].Contains($f)) { $byEvidence[$k].Add($f) }
        }
    }
    foreach ($list in $byEvidence.Values) { if ($list.Count -gt 1) { foreach ($f in $list) { $f.ambiguous = $true } } }
    foreach ($f in $findings) {
        if ($f.ambiguous) { $f.score -= 0.5 }
        $f.label = if ($f.ambiguous -or $f.confidence -eq 'low') { 'Possible cause' } else { 'Likely cause' }
        $f.Remove('signalKey')
    }
    return , @($findings | Sort-Object -Property @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { $_.ruleId } })
}

function Get-AdTimeline {
    param($Event, $PolicyDetails, $LogAnalyses)
    $items = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($t, $label, $detail, $kind)
        if ($t) { $items.Add([ordered]@{ time = $t.ToString('o'); label = $label; detail = $detail; kind = $kind }) }
    }
    $reg = Get-AdDateValue (Get-AdProp $Event 'deviceRegisteredDateTime')
    $start = Get-AdDateValue (Get-AdProp $Event 'deploymentStartDateTime')
    $enr = Get-AdDateValue (Get-AdProp $Event 'enrollmentStartDateTime')
    $end = Get-AdDateValue (Get-AdProp $Event 'deploymentEndDateTime')
    & $add $reg 'Device registered with Autopilot' '' 'info'
    & $add $start 'Deployment started' '' 'info'
    & $add $enr 'MDM enrollment started' '' 'info'
    $cursor = if ($enr) { $enr } else { $start }
    foreach ($pair in @(@('devicePreparationDuration', 'ESP device preparation finished'), @('deviceSetupDuration', 'ESP device setup finished'), @('accountSetupDuration', 'ESP account setup finished'))) {
        $sec = ConvertFrom-AdIsoDuration (Get-AdProp $Event $pair[0])
        if ($cursor -and $sec) { $cursor = $cursor.AddSeconds($sec); & $add $cursor $pair[1] ("after {0:N0} min" -f ($sec / 60)) 'info' }
    }
    foreach ($p in @($PolicyDetails)) {
        if ($null -eq $p) { continue }
        $st = [string](Get-AdProp $p 'complianceStatus')
        if ($st -in 'error', 'notCompliant') {
            & $add (Get-AdDateValue (Get-AdProp $p 'lastReportedDateTime')) "$(Get-AdProp $p 'displayName'): $st" ("Error code {0}" -f ((ConvertTo-AdHexCode (Get-AdProp $p 'errorCode')) ?? 'not reported')) 'error'
        }
    }
    $state = Get-AdStatus $Event
    & $add $end "Deployment ended: $state" '' $(if ($state -eq 'Failed') { 'error' } else { 'info' })
    foreach ($la in @($LogAnalyses)) {
        if ($null -eq $la) { continue }
        foreach ($e in @($la.autopilotEvents | Where-Object { $_ -and $_.level -in 'Error', 'Warning' } | Select-Object -First 25)) {
            & $add ([datetime]$e.time).ToUniversalTime() "Autopilot event $($e.id) ($($e.level))" $e.message $(if ($e.level -eq 'Error') { 'error' } else { 'warning' })
        }
    }
    return , @($items | Sort-Object { $_.time })
}

function ConvertTo-AdDeploymentModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Dataset,
        [Parameter(Mandatory)][object[]]$Rules,
        [object[]]$LogAnalyses = @()
    )
    $identityBySerial = @{}
    foreach ($i in @($Dataset.identities)) {
        $s = [string](Get-AdProp $i 'serialNumber')
        if ($s) { $identityBySerial[$s.ToUpperInvariant()] = $i }
    }

    # Assign each log analysis to the most relevant deployment of the same device.
    $events = @($Dataset.events | Sort-Object { Get-AdDeploymentDate $_ } -Descending)
    $logsByEvent = @{}
    foreach ($la in @($LogAnalyses)) {
        if ($null -eq $la) { continue }
        $candidates = @($events | Where-Object {
                ($la.serialNumber -and [string](Get-AdProp $_ 'deviceSerialNumber') -eq $la.serialNumber) -or
                ($la.managedDeviceId -and [string](Get-AdProp $_ 'deviceId') -eq $la.managedDeviceId)
            })
        $la.matchedDeploymentIds = @()
        if (-not $candidates) { continue }
        $logTime = if ($la.newestEventTime) { ([datetime]$la.newestEventTime).ToUniversalTime().AddDays(1) } else { $null }
        $pick = if ($logTime) { $candidates | Where-Object { (Get-AdDeploymentDate $_) -le $logTime } | Select-Object -First 1 } else { $null }
        if (-not $pick) { $pick = $candidates[0] }
        $id = [string](Get-AdProp $pick 'id')
        if (-not $logsByEvent.ContainsKey($id)) { $logsByEvent[$id] = [System.Collections.Generic.List[object]]::new() }
        $logsByEvent[$id].Add($la)
        $la.matchedDeploymentIds = @($id)
        $la.matchedBy = if ($la.serialNumber -and [string](Get-AdProp $pick 'deviceSerialNumber') -eq $la.serialNumber) { 'serial number' } else { 'Intune device ID' }
    }

    $models = foreach ($ev in $events) {
        $id = [string](Get-AdProp $ev 'id')
        $pol = @(if ($Dataset.policyDetails -and $Dataset.policyDetails.ContainsKey($id)) { $Dataset.policyDetails[$id] })
        $logs = if ($logsByEvent.ContainsKey($id)) { $logsByEvent[$id].ToArray() } else { @() }
        $serial = [string](Get-AdProp $ev 'deviceSerialNumber')
        $identity = if ($serial -and $identityBySerial.ContainsKey($serial.ToUpperInvariant())) { $identityBySerial[$serial.ToUpperInvariant()] } else { $null }
        $identityId = [string](Get-AdProp $identity 'id')
        $prof = if ($identityId -and $Dataset.profiles -and $Dataset.profiles.Contains($identityId)) { $Dataset.profiles[$identityId] } else { $null }

        $flow = Get-AdFlow $ev
        $status = Get-AdStatus $ev
        $graphPhase = Get-AdGraphPhase $ev

        $evidence = [System.Collections.Generic.List[object]]::new()
        foreach ($e in (Get-AdGraphEvidence $ev $pol)) { $evidence.Add($e) }
        foreach ($la in $logs) { foreach ($e in (Get-AdLogEvidence $la)) { $evidence.Add($e) } }
        $findings = if ($status -in 'Failed', 'Not available' -or $logs) {
            Find-AdRuleMatches -Evidence $evidence.ToArray() -Rules $Rules -FlowTags $flow.tags -GraphPhase $graphPhase
        } else { @() }

        $phase = 'Not available'; $phaseSource = 'none'
        if ($status -eq 'Success') { $phase = 'Completed'; $phaseSource = 'graph' }
        elseif ($status -eq 'In progress') { $phase = 'In progress'; $phaseSource = 'graph' }
        elseif ($graphPhase) { $phase = $graphPhase; $phaseSource = 'graph' }
        elseif ($findings.Count) { $phase = $findings[0].phase; $phaseSource = 'rule' }

        $profileName = [string](Get-AdProp $ev 'windowsAutopilotDeploymentProfileDisplayName')
        $assigned = [string](Get-AdProp (Get-AdProp $prof 'deploymentProfile') 'displayName')
        $intended = [string](Get-AdProp (Get-AdProp $prof 'intendedDeploymentProfile') 'displayName')
        if (-not $profileName) { $profileName = $assigned }

        $codes = @($evidence | Where-Object { $_.kind -eq 'errorCode' } | ForEach-Object { [string]$_.value } | Select-Object -Unique)
        $failedItems = @($pol | Where-Object { $_ -and [string](Get-AdProp $_ 'complianceStatus') -in 'error', 'notCompliant' } | ForEach-Object {
                [ordered]@{
                    name = [string](Get-AdProp $_ 'displayName'); type = [string](Get-AdProp $_ 'policyType')
                    status = [string](Get-AdProp $_ 'complianceStatus'); errorCode = ConvertTo-AdHexCode (Get-AdProp $_ 'errorCode')
                    trackedOnEsp = [bool](Get-AdProp $_ 'trackedOnEnrollmentStatus')
                }
            })
        # ESP-tracked Win32 apps in Error from matched diagnostics. This is the only source of failing items
        # when Graph doesn't expose policyStatusDetails.
        $failedItems = @($failedItems) + @(foreach ($la in $logs) {
                foreach ($e in @($la.espTracking | Where-Object { $_ -and [int]$_.installationState -eq 4 })) {
                    $appId = if ($e.item -match '(?i)^Win32App_([0-9a-f\-]{36})') { $Matches[1] } else { $e.item }
                    [ordered]@{ name = "Win32 app $appId"; type = "application (ESP $($e.scope.ToLowerInvariant()), from diagnostics)"; status = 'error'; errorCode = $null; trackedOnEsp = $true }
                }
            })
        $total = ConvertFrom-AdIsoDuration (Get-AdProp $ev 'deploymentTotalDuration')
        if (-not $total) { $total = ConvertFrom-AdIsoDuration (Get-AdProp $ev 'deploymentDuration') }
        if (-not $total) {
            $s = Get-AdDateValue (Get-AdProp $ev 'deploymentStartDateTime'); $e2 = Get-AdDateValue (Get-AdProp $ev 'deploymentEndDateTime')
            if ($s -and $e2 -and $e2 -gt $s) { $total = [int]($e2 - $s).TotalSeconds }
        }
        # Deployment date = start (as in the Intune portal). dayCandidates holds every known date so the
        # frontend date filter can't hide a row that falls in the range on any of them.
        $allDates = @(Get-AdEventDates $ev)
        $when = $allDates | Select-Object -First 1

        $gaps = @(foreach ($f in 'deploymentState', 'enrollmentType', 'deviceSerialNumber', 'windowsAutopilotDeploymentProfileDisplayName', 'deploymentTotalDuration') {
                if ([string]::IsNullOrEmpty([string](Get-AdProp $ev $f))) { $f }
            })

        [ordered]@{
            id                  = $id
            eventDateTime       = if ($when) { $when.ToString('o') } else { $null }
            day                 = if ($when) { $when.ToString('yyyy-MM-dd') } else { $null }
            dayCandidates       = @($allDates | ForEach-Object { $_.ToString('yyyy-MM-dd') } | Select-Object -Unique)
            status              = $status
            deploymentState     = [string](Get-AdProp $ev 'deploymentState')
            phase               = $phase
            phaseSource         = $phaseSource
            flow                = $flow.label
            flowKey             = $flow.key
            deviceName          = [string](Get-AdProp $ev 'managedDeviceName')
            serial              = $serial
            upn                 = [string](Get-AdProp $ev 'userPrincipalName')
            manufacturer        = [string](Get-AdProp $identity 'manufacturer')
            model               = [string](Get-AdProp $identity 'model')
            groupTag            = [string](Get-AdProp $identity 'groupTag')
            profile             = $profileName
            assignedProfile     = $assigned
            intendedProfile     = $intended
            profileMismatch     = [bool]($assigned -and $intended -and $assigned -ne $intended)
            espProfile          = [string](Get-AdProp $ev 'windows10EnrollmentCompletionPageConfigurationDisplayName')
            osVersion           = [string](Get-AdProp $ev 'osVersion')
            durationSec         = $total
            durations           = [ordered]@{
                devicePreparation = ConvertFrom-AdIsoDuration (Get-AdProp $ev 'devicePreparationDuration')
                deviceSetup       = ConvertFrom-AdIsoDuration (Get-AdProp $ev 'deviceSetupDuration')
                accountSetup      = ConvertFrom-AdIsoDuration (Get-AdProp $ev 'accountSetupDuration')
            }
            enrollmentState     = [string](Get-AdProp $ev 'enrollmentState')
            deviceSetupStatus   = [string](Get-AdProp $ev 'deviceSetupStatus')
            accountSetupStatus  = [string](Get-AdProp $ev 'accountSetupStatus')
            enrollmentFailure   = [string](Get-AdProp $ev 'enrollmentFailureDetails')
            targetedAppCount    = Get-AdProp $ev 'targetedAppCount'
            targetedPolicyCount = Get-AdProp $ev 'targetedPolicyCount'
            managedDeviceId     = [string](Get-AdProp $ev 'deviceId')
            autopilotIdentityId = $identityId
            errorCodes          = $codes
            failedItems         = $failedItems
            policyItemCount     = $pol.Count
            policyDetailsLoaded = [bool]($Dataset.policyDetails -and $Dataset.policyDetails.ContainsKey($id))
            timeline            = Get-AdTimeline $ev $pol $logs
            evidence            = $evidence.ToArray()
            findings            = $findings
            logAnalysisIds      = @($logs | ForEach-Object { $_.id })
            dataGaps            = $gaps
        }
    }
    return , @($models)
}

function Get-AdStructuralImprovements {
    param([object[]]$Deployments)
    $agg = @{}
    foreach ($d in @($Deployments)) {
        if ($null -eq $d -or $d.status -ne 'Failed') { continue }
        $seen = @{}
        foreach ($f in @($d.findings)) {
            $key = $f.structuralAction
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            if (-not $agg.ContainsKey($key)) {
                $agg[$key] = [ordered]@{ structuralAction = $key; score = 0.0; deployments = 0; ambiguousDeployments = 0; ruleIds = [System.Collections.Generic.HashSet[string]]::new(); phases = [System.Collections.Generic.HashSet[string]]::new(); sourceUrls = [System.Collections.Generic.HashSet[string]]::new(); confidence = $f.confidence }
            }
            $a = $agg[$key]
            $a.deployments++
            if ($f.ambiguous) { $a.ambiguousDeployments++ }
            $a.score += [double]$script:AdConfidenceWeight[[string]$f.confidence] * $(if ($f.ambiguous) { 0.5 } else { 1 }) * $(if ($f.generic) { 0.25 } else { 1 })
            [void]$a.ruleIds.Add($f.ruleId); [void]$a.phases.Add($f.phase); [void]$a.sourceUrls.Add($f.sourceUrl)
        }
    }
    $rank = 0
    return , @($agg.Values | Sort-Object -Property @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { $_.deployments }; Descending = $true } | ForEach-Object {
            $rank++
            [ordered]@{
                rank = $rank; structuralAction = $_.structuralAction; score = [math]::Round($_.score, 1)
                deployments = $_.deployments; ambiguousDeployments = $_.ambiguousDeployments; confidence = $_.confidence
                ruleIds = @($_.ruleIds); phases = @($_.phases); sourceUrls = @($_.sourceUrls)
            }
        })
}
