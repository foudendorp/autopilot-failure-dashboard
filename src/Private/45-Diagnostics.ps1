# Intune "Collect diagnostics" access through Microsoft Graph.
#
# Microsoft's documentation is contradictory here, and the app is built to handle both outcomes:
#   * Graph documents deviceLogCollectionResponse and the createDownloadUrl action (beta).
#   * The Intune "Collect diagnostics" article states: "Diagnostics can't be collected or downloaded
#     by calling Microsoft Graph directly. Use the Intune admin center to collect and download diagnostics."
# The capability test therefore checks what actually works for the signed-in account. It only
# lists existing collections (GET) and requests a download URL (the single approved POST
# exception). It never creates a collection request. When that fails, the UI offers manual upload.

$script:AdDiagDocsUrl = 'https://learn.microsoft.com/en-us/intune/device-management/actions/collect-diagnostics'

function Get-AdDiagnosticsList {
    param([Parameter(Mandatory)][scriptblock]$TokenProvider, [Parameter(Mandatory)][string]$ManagedDeviceId, $Config)
    if (-not (Test-AdGuid $ManagedDeviceId)) { throw 'Invalid managed device ID.' }
    $items = Get-AdGraphCollection -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$ManagedDeviceId/logCollectionRequests" -TokenProvider $TokenProvider -MaxRetries ([int]$Config.graphMaxRetries)
    return , @($items | ForEach-Object {
            [ordered]@{
                id              = [string](Get-AdProp $_ 'id')
                status          = [string](Get-AdProp $_ 'status')
                requested       = [string](Get-AdProp $_ 'requestedDateTimeUTC')
                received        = [string](Get-AdProp $_ 'receivedDateTimeUTC')
                expires         = [string](Get-AdProp $_ 'expirationDateTimeUTC')
                sizeInKB        = Get-AdProp $_ 'sizeInKB'
                initiatedByUser = [string](Get-AdProp $_ 'initiatedByUserPrincipalName')
                managedDeviceId = $ManagedDeviceId
            }
        })
}

function Get-AdDiagnosticsDownloadUrl {
    param([Parameter(Mandatory)][scriptblock]$TokenProvider, [Parameter(Mandatory)][string]$ManagedDeviceId, [Parameter(Mandatory)][string]$RequestId, $Config)
    if (-not (Test-AdGuid $ManagedDeviceId) -or $RequestId -notmatch '^[A-Za-z0-9_\-]{1,128}$') { throw 'Invalid identifiers.' }
    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$ManagedDeviceId/logCollectionRequests/$RequestId/createDownloadUrl"
    $resp = Invoke-AdGraphRequest -Method POST -Uri $uri -TokenProvider $TokenProvider -MaxRetries ([int]$Config.graphMaxRetries) -AllowDiagnosticsPost ([bool]$Config.allowDiagnosticsDownloadPost)
    $url = [string](Get-AdProp $resp 'value')
    if (-not (Test-AdDiagnosticsBlobUrl $url)) { throw 'The download URL returned by Graph is not an expected Azure Blob Storage https URL; refused.' }
    return $url
}

function Test-AdDiagnosticsBlobUrl {
    param([AllowNull()][string]$Url)
    $u = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return $false }
    return ($u.Scheme -eq 'https' -and $u.IsDefaultPort -and -not $u.UserInfo -and $u.Host -match '^[a-z0-9]{3,63}\.blob\.core\.windows\.net$')
}

function Get-AdDiagnosticsContent {
    <# Downloads the diagnostics archive from the pre-signed blob URL. No Graph token is sent. #>
    param([Parameter(Mandatory)][string]$Url, [long]$MaxBytes = 250MB)
    if (-not (Test-AdDiagnosticsBlobUrl $Url)) { throw 'Refusing to download from an unexpected host.' }
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [timespan]::FromMinutes(10)
    try {
        $resp = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) { throw "Download failed with HTTP $([int]$resp.StatusCode)." }
        $len = $resp.Content.Headers.ContentLength
        if ($len -and $len -gt $MaxBytes) { throw "Diagnostics archive is larger than the $([int]($MaxBytes / 1MB)) MB limit." }
        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $ms = [System.IO.MemoryStream]::new()
        try {
            $buffer = [byte[]]::new(81920)
            while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($ms.Length + $n -gt $MaxBytes) { throw "Diagnostics archive is larger than the $([int]($MaxBytes / 1MB)) MB limit." }
                $ms.Write($buffer, 0, $n)
            }
            return , $ms.ToArray()
        }
        finally { $stream.Dispose(); $ms.Dispose() }
    }
    finally { $client.Dispose(); $handler.Dispose() }
}

function Test-AdDiagnosticsCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$TokenProvider, [Parameter(Mandatory)]$Config, [string]$ManagedDeviceId)
    $steps = [System.Collections.Generic.List[object]]::new()
    $result = [ordered]@{
        testedUtc = [datetime]::UtcNow.ToString('o'); managedDeviceId = $ManagedDeviceId
        canList = $false; canDownload = $false; collections = @(); steps = $null
        summary = ''; docsUrl = $script:AdDiagDocsUrl
        docsNote = 'Microsoft''s Collect diagnostics article states that diagnostics can''t be collected or downloaded by calling Microsoft Graph directly, and that the Intune admin center should be used. The Graph createDownloadUrl action is documented separately. This test shows what works for your account.'
    }
    $step = { param($name, $method, $endpoint, $status, $message) $steps.Add([ordered]@{ name = $name; method = $method; endpoint = $endpoint; status = $status; message = $message }) }

    if (-not (Test-AdGuid $ManagedDeviceId)) {
        & $step 'Select a device' '-' '-' 'skipped' 'No Intune managed device ID is available (refresh data first; failed deployments before MDM enrollment have no device ID).'
        $result.summary = 'Not tested: no managed device available to test against. Use manual upload.'
        $result.steps = $steps.ToArray(); return $result
    }

    $listEndpoint = '/beta/deviceManagement/managedDevices/{id}/logCollectionRequests'
    try {
        $list = Get-AdDiagnosticsList -TokenProvider $TokenProvider -ManagedDeviceId $ManagedDeviceId -Config $Config
        $result.canList = $true
        $result.collections = $list
        & $step 'List diagnostics collections' 'GET' $listEndpoint 'ok' "$($list.Count) collection(s) found for this device."
    }
    catch {
        $info = Get-AdGraphErrorInfo $_
        $status = if ($info.status -eq 403) { 'forbidden' } elseif ($info.status -in 400, 404, 501) { 'unsupported' } else { 'error' }
        $msg = switch ($status) {
            'forbidden' { 'Graph returned 403 Forbidden. The account or app permissions don''t allow listing diagnostics (an Intune role with Remote tasks/Collect diagnostics and managed device read is needed).' }
            'unsupported' { "Graph returned $($info.status): listing diagnostics isn't supported for this device or tenant." }
            default { $info.message }
        }
        & $step 'List diagnostics collections' 'GET' $listEndpoint $status $msg
        & $step 'Request download URL' 'POST' '.../logCollectionRequests/{id}/createDownloadUrl' 'skipped' 'Skipped because listing failed.'
        $result.summary = 'Diagnostics are not accessible through Graph for this account. Download the diagnostics from the Intune admin center and upload them here.'
        $result.steps = $steps.ToArray(); return $result
    }

    $completed = @($result.collections | Where-Object { $_.status -match '(?i)^completed$' } | Select-Object -First 1)
    if (-not $Config.allowDiagnosticsDownloadPost) {
        & $step 'Request download URL' 'POST' '.../logCollectionRequests/{id}/createDownloadUrl' 'skipped' 'Disabled by allowDiagnosticsDownloadPost = false in settings.json.'
    }
    elseif (-not $completed) {
        & $step 'Request download URL' 'POST' '.../logCollectionRequests/{id}/createDownloadUrl' 'skipped' 'No completed collection exists for this device, so download could not be tested. The app never creates a collection request.'
    }
    else {
        try {
            $null = Get-AdDiagnosticsDownloadUrl -TokenProvider $TokenProvider -ManagedDeviceId $ManagedDeviceId -RequestId $completed[0].id -Config $Config
            $result.canDownload = $true
            & $step 'Request download URL' 'POST' '.../logCollectionRequests/{id}/createDownloadUrl' 'ok' 'A download URL was issued (not stored or shown).'
        }
        catch {
            $info = Get-AdGraphErrorInfo $_
            $status = if ($info.status -eq 403) { 'forbidden' } elseif ($info.status -in 400, 404, 405, 501) { 'unsupported' } else { 'error' }
            & $step 'Request download URL' 'POST' '.../logCollectionRequests/{id}/createDownloadUrl' $status "$($info.status) $($info.code): $($info.message)"
        }
    }
    $result.summary = if ($result.canDownload) { 'Diagnostics can be listed and downloaded with this account.' }
    elseif ($result.canList) { 'Diagnostics can be listed, but download through Graph was not confirmed. Download them in the Intune admin center and upload them here.' }
    else { 'Diagnostics are not accessible through Graph.' }
    $result.steps = $steps.ToArray()
    return $result
}
