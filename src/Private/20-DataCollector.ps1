# Retrieves Autopilot data from Microsoft Graph (read-only, via Invoke-AdGraphRequest).
# All endpoints used here are /beta and are labelled as such in the UI.

$script:AdGraphBase = 'https://graph.microsoft.com/beta'
$script:AdSafeId = '^[A-Za-z0-9_\-]{1,128}$'

function New-AdSourceRecord {
    param([string]$Name, [string]$Endpoint, [bool]$Beta = $true)
    [ordered]@{ name = $Name; endpoint = $Endpoint; beta = $Beta; status = 'pending'; count = $null; message = '' }
}

function Set-AdSourceError {
    param($Source, $ErrorRecord)
    $info = Get-AdGraphErrorInfo $ErrorRecord
    $Source.status = if ($info.status -eq 403) { 'forbidden' } elseif ($info.status -in 400, 404, 501) { 'unsupported' } else { 'error' }
    $Source.message = switch ($Source.status) {
        'forbidden' { "Access denied (403). The signed-in account or the app's consented permissions don't allow this call. $($info.message)" }
        'unsupported' { "Not supported or not found ($($info.status)). $($info.message)" }
        default { "$($info.code): $($info.message)" }
    }
    return $info
}

function Get-AdDateValue {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal,AssumeUniversal', [ref]$d)) {
        if ($d.Year -le 1) { return $null }   # Graph uses 0001-01-01 for "not set"
        return $d
    }
    return $null
}

function Get-AdProp {
    <# Safe property read for objects that may be missing fields (Graph beta, older payloads). #>
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Invoke-AdDataRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$TokenProvider,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To,
        [scriptblock]$Progress = { param($Percent, $Message) }
    )
    $retries = [int]$Config.graphMaxRetries
    $sources = [System.Collections.Generic.List[object]]::new()

    # 1. Autopilot events -------------------------------------------------------------------
    & $Progress 5 'Retrieving Autopilot deployment events'
    $srcEvents = New-AdSourceRecord 'Autopilot deployment events' '/beta/deviceManagement/autopilotEvents'
    $sources.Add($srcEvents)
    # No server-side $filter: `eventDateTime ge/le` makes Graph drop deployments whose eventDateTime is
    # empty (0001-01-01) or differs from the deployment date, while the Intune portal still shows them.
    # All pages are retrieved and the date range is applied locally on every known date of a row.
    $pageInfo = @{ n = 0 }
    $rawEvents = @()
    try {
        # Get-AdGraphCollection returns the array as ONE object: don't wrap it in @() (that nests it).
        $rawEvents = Get-AdGraphCollection -Uri "$script:AdGraphBase/deviceManagement/autopilotEvents" -TokenProvider $TokenProvider -MaxRetries $retries -OnPage {
            param($p, $n) $pageInfo.n = $p; & $Progress 5 "Retrieving Autopilot deployment events (page $p, $n events)"
        }
        if ($null -eq $rawEvents) { $rawEvents = @() }
        $srcEvents.message = 'All events retrieved; date range applied locally on deployment start, enrollment start, event and end dates.'
    }
    catch { $null = Set-AdSourceError $srcEvents $_ }
    $selection = Select-AdEventsInRange -Events $rawEvents -From $From -To $To
    $events = $selection.Kept
    if ($srcEvents.status -eq 'pending') { $srcEvents.status = 'ok'; $srcEvents.count = $events.Count }

    # 2. Policy status details per event -------------------------------------------------------
    # The current Graph beta schema documents no relationships on deviceManagementAutopilotEvent, and
    # tenants answer 400 "Resource not found for the segment 'policyStatusDetails'". The call is still
    # tried (older tenants/regions may serve it), but the first such answer stops all further calls.
    $srcPol = New-AdSourceRecord 'Policy and app status per deployment' '/beta/deviceManagement/autopilotEvents/{id}/policyStatusDetails'
    $sources.Add($srcPol)
    $policyDetails = @{}
    # Off by default: the endpoint no longer exists in Graph beta, so calling it only produces a 400.
    $targets = if (-not $Config.tryPolicyStatusDetails) { @() } else {
        @($events | Where-Object {
                $Config.policyDetailsForAllEvents -or ((Get-AdProp $_ 'deploymentState') -notin @('success', 'successOnRetry'))
            })
    }
    if (-not $Config.tryPolicyStatusDetails) {
        $srcPol.status = 'skipped'
        $srcPol.message = 'Not requested: Microsoft removed policyStatusDetails from Autopilot events in Graph beta (the documented schema lists no relationships). Failing apps come from uploaded diagnostics (ESP tracking). Set "tryPolicyStatusDetails": true to try it anyway.'
    }
    $i = 0; $polErrors = 0; $consecutive400 = 0; $stopReason = $null
    foreach ($ev in $targets) {
        $i++
        $id = [string](Get-AdProp $ev 'id')
        if ($id -notmatch $script:AdSafeId) { continue }
        if ($i % 5 -eq 1) { & $Progress (10 + [int](40 * $i / [math]::Max($targets.Count, 1))) "Retrieving policy status details ($i of $($targets.Count))" }
        try {
            $items = Get-AdGraphCollection -Uri "$script:AdGraphBase/deviceManagement/autopilotEvents/$id/policyStatusDetails" -TokenProvider $TokenProvider -MaxRetries $retries
            $policyDetails[$id] = if ($null -eq $items) { @() } else { $items }
            $consecutive400 = 0
        }
        catch {
            $polErrors++
            $info = Set-AdSourceError $srcPol $_
            if ($info.status -in 401, 403) { break }
            if ($info.status -eq 400 -and $policyDetails.Count -eq 0) {
                $consecutive400++
                if ($info.message -match "segment 'policyStatusDetails'|property named 'policyStatusDetails'") { $stopReason = 'removed'; break }
                if ($consecutive400 -ge 3) { $stopReason = 'repeated'; break }
            }
        }
    }
    if ($stopReason) {
        $srcPol.status = 'unsupported'
        $srcPol.message = if ($stopReason -eq 'removed') {
            'Not available: this tenant''s Graph beta no longer exposes policyStatusDetails on Autopilot events (the documented schema lists no relationships). Failing apps and policies come from uploaded diagnostics (ESP tracking) instead.'
        }
        else { "Stopped after $consecutive400 consecutive 400 responses. " + $srcPol.message }
    }
    elseif ($srcPol.status -eq 'pending' -or ($srcPol.status -in 'error', 'unsupported' -and $polErrors -lt $targets.Count)) {
        if ($polErrors) { $srcPol.message = "$polErrors of $($targets.Count) lookups failed. " + $srcPol.message }
        $srcPol.status = if ($polErrors) { 'partial' } else { 'ok' }
    }
    $srcPol.count = $policyDetails.Count

    # 3. Autopilot device identities ------------------------------------------------------------
    & $Progress 55 'Retrieving Autopilot device identities'
    $srcIds = New-AdSourceRecord 'Autopilot registered devices' '/beta/deviceManagement/windowsAutopilotDeviceIdentities'
    $sources.Add($srcIds)
    $identities = @()
    try {
        $identities = Get-AdGraphCollection -Uri "$script:AdGraphBase/deviceManagement/windowsAutopilotDeviceIdentities" -TokenProvider $TokenProvider -MaxRetries $retries -OnPage {
            param($p, $n) & $Progress 55 "Retrieving Autopilot device identities (page $p, $n devices)"
        }
        $srcIds.status = 'ok'; $srcIds.count = $identities.Count
    }
    catch { $null = Set-AdSourceError $srcIds $_ }

    # 4. Deployment + intended deployment profile per device in scope ---------------------------
    $srcProf = New-AdSourceRecord 'Deployment and intended deployment profile per device' '/beta/deviceManagement/windowsAutopilotDeviceIdentities/{id}?$expand=deploymentProfile,intendedDeploymentProfile'
    $sources.Add($srcProf)
    $profiles = @{}
    $serials = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($ev in $events) { $s = [string](Get-AdProp $ev 'deviceSerialNumber'); if ($s) { [void]$serials.Add($s) } }
    $inScope = @($identities | Where-Object { $serials.Contains([string](Get-AdProp $_ 'serialNumber')) } | Select-Object -First ([int]$Config.maxProfileLookups))
    $i = 0
    foreach ($idObj in $inScope) {
        $i++
        $id = [string](Get-AdProp $idObj 'id')
        if ($id -notmatch $script:AdSafeId) { continue }
        if ($i % 5 -eq 1) { & $Progress (60 + [int](30 * $i / [math]::Max($inScope.Count, 1))) "Retrieving deployment profiles ($i of $($inScope.Count))" }
        try {
            $r = Invoke-AdGraphRequest -Uri "$script:AdGraphBase/deviceManagement/windowsAutopilotDeviceIdentities/$id`?`$expand=deploymentProfile,intendedDeploymentProfile" -TokenProvider $TokenProvider -MaxRetries $retries
            $profiles[$id] = [ordered]@{
                deploymentProfile         = Get-AdProp $r 'deploymentProfile'
                intendedDeploymentProfile = Get-AdProp $r 'intendedDeploymentProfile'
            }
        }
        catch {
            $info = Set-AdSourceError $srcProf $_
            if ($info.status -in 401, 403) { break }
        }
    }
    if ($srcProf.status -eq 'pending') { $srcProf.status = 'ok' }
    $srcProf.count = $profiles.Count
    if ($identities.Count -and $inScope.Count -lt @($identities | Where-Object { $serials.Contains([string](Get-AdProp $_ 'serialNumber')) }).Count) {
        $srcProf.message = "Limited to $($Config.maxProfileLookups) devices (maxProfileLookups)."
    }

    # 5. Autopilot device preparation -----------------------------------------------------------
    & $Progress 92 'Checking Autopilot device preparation data'
    $devicePrep = Get-AdDevicePreparationInfo -TokenProvider $TokenProvider -Config $Config -Sources $sources

    & $Progress 100 'Done'
    return [ordered]@{
        mode          = 'tenant'
        refreshedUtc  = [datetime]::UtcNow.ToString('o')
        from          = $From.ToUniversalTime().ToString('o')
        to            = $To.ToUniversalTime().ToString('o')
        events        = $events
        policyDetails = $policyDetails
        identities    = $identities
        profiles      = $profiles
        devicePrep    = $devicePrep
        sources       = $sources.ToArray()
        rawEvents     = $rawEvents          # all rows as returned by Graph (in memory only), for pipeline diagnostics
        stats         = New-AdPipelineStats -Selection $selection -Pages $pageInfo.n -Endpoint '/beta/deviceManagement/autopilotEvents (no $filter, all pages)'
    }
}

function Get-AdDevicePreparationInfo {
    <# Device preparation (Autopilot v2) deployment status is exposed by Microsoft only through the
       Intune reports export API (reportName AutopilotV2DeploymentStatus via POST .../reports/exportJobs).
       That POST is outside this app's read-only policy, so deployment-level data is reported as
       "Not available". Policies are listed with GET when the Configuration read scope is granted. #>
    param([scriptblock]$TokenProvider, $Config, $Sources)
    $src = New-AdSourceRecord 'Autopilot device preparation policies' '/beta/deviceManagement/configurationPolicies (filtered locally)'
    $Sources.Add($src)
    $result = [ordered]@{
        deploymentDataAvailable = $false
        deploymentDataMessage   = 'Not available. Microsoft exposes device preparation deployment status (report AutopilotV2DeploymentStatus) only through POST /beta/deviceManagement/reports/exportJobs. That call is not part of this read-only app''s single approved POST exception, so device preparation deployments are not retrieved. Use Intune admin center > Devices > Windows > Enrollment > Windows Autopilot device preparation deployments.'
        policies                = @()
    }
    if (-not $Config.requestConfigurationReadScope) {
        $src.status = 'skipped'; $src.message = 'DeviceManagementConfiguration.Read.All is not requested (requestConfigurationReadScope = false).'
        return $result
    }
    try {
        $sel = [uri]::EscapeDataString('id,name,technologies,platforms,templateReference,lastModifiedDateTime')
        $all = Get-AdGraphCollection -Uri "$script:AdGraphBase/deviceManagement/configurationPolicies?`$select=$sel" -TokenProvider $TokenProvider -MaxRetries ([int]$Config.graphMaxRetries)
        $prep = @($all | Where-Object {
                $tr = Get-AdProp $_ 'templateReference'
                $family = [string](Get-AdProp $tr 'templateFamily')
                $tech = [string](Get-AdProp $_ 'technologies')
                $family -match '(?i)enrollmentConfiguration|devicePreparation' -or $tech -match '(?i)\benrollment\b'
            } | ForEach-Object { [ordered]@{ id = Get-AdProp $_ 'id'; name = Get-AdProp $_ 'name'; lastModified = Get-AdProp $_ 'lastModifiedDateTime' } })
        $result.policies = $prep
        $src.status = 'ok'; $src.count = $prep.Count
        $src.message = 'Identified by template family / technologies (best effort; beta schema).'
    }
    catch { $null = Set-AdSourceError $src $_ }
    return $result
}


function Get-AdEventDates {
    <# All usable dates of an Autopilot event (Graph uses 0001-01-01 for "not set"). #>
    param($Event)
    @(foreach ($f in 'deploymentStartDateTime', 'enrollmentStartDateTime', 'eventDateTime', 'deploymentEndDateTime') {
            $d = Get-AdDateValue (Get-AdProp $Event $f)
            if ($d) { $d }
        })
}

function Select-AdEventsInRange {
    <#
      Applies the date range locally. A row is kept when ANY of its known dates falls in the range,
      or when it has no usable date at all (shown as "Not available", never silently dropped).
    #>
    param([object[]]$Events, [Parameter(Mandatory)][datetime]$From, [Parameter(Mandatory)][datetime]$To)
    $f = $From.ToUniversalTime(); $t = $To.ToUniversalTime()
    $kept = [System.Collections.Generic.List[object]]::new()
    $excluded = 0; $noDate = 0
    foreach ($ev in @($Events)) {
        if ($null -eq $ev) { continue }
        $dates = Get-AdEventDates $ev
        if (-not $dates) { $noDate++; $kept.Add($ev); continue }
        if (@($dates | Where-Object { $_ -ge $f -and $_ -le $t }).Count) { $kept.Add($ev) } else { $excluded++ }
    }
    $all = @($Events | Where-Object { $null -ne $_ })
    [pscustomobject]@{ Kept = $kept.ToArray(); All = $all; Raw = $all.Count; ExcludedByDate = $excluded; NoDate = $noDate }
}

function New-AdPipelineStats {
    param([Parameter(Mandatory)]$Selection, [int]$Pages, [string]$Endpoint)
    # Raw deploymentState values exactly as received (case preserved, ordinal keys) -> count.
    $states = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($ev in $Selection.All) {
        $raw = Get-AdProp $ev 'deploymentState'
        $k = if ($null -eq $raw -or [string]$raw -eq '') { '(empty)' } else { [string]$raw }
        $states[$k] = 1 + $(if ($states.ContainsKey($k)) { $states[$k] } else { 0 })
    }
    [ordered]@{
        endpoint            = $Endpoint
        pages               = $Pages
        rawRows             = $Selection.Raw
        excludedByDate      = $Selection.ExcludedByDate
        rowsWithoutDate     = $Selection.NoDate
        keptRows            = @($Selection.Kept).Count
        rawDeploymentStates = $states
    }
}