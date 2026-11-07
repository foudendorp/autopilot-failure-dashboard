# Central Microsoft Graph client. Every Graph call in the app goes through
# Invoke-AdGraphRequest, which enforces the read-only policy before a request leaves the process:
#   * only https://graph.microsoft.com is contacted (the token is never sent anywhere else)
#   * only GET is allowed
#   * ONE documented exception: POST .../logCollectionRequests/{id}/createDownloadUrl, which
#     returns a short-lived download URL for an existing Intune diagnostics collection and
#     changes nothing in the tenant. It can be switched off with allowDiagnosticsDownloadPost.

$script:AdGraphHost = 'graph.microsoft.com'

$script:AdApprovedPostExceptions = @(
    [pscustomobject]@{
        Name    = 'Intune diagnostics download URL (deviceLogCollectionResponse: createDownloadUrl)'
        Pattern = '^/beta/deviceManagement/managedDevices/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/logCollectionRequests/[A-Za-z0-9_\-]{1,128}/createDownloadUrl$'
        Docs    = 'https://learn.microsoft.com/en-us/graph/api/intune-devices-devicelogcollectionresponse-createdownloadurl?view=graph-rest-beta'
    }
)

function Get-AdApprovedPostExceptions { $script:AdApprovedPostExceptions }

function New-AdGraphException {
    param([int]$Status, [string]$Code, [string]$Message, [string]$RequestId, [string]$Uri)
    $ex = [System.Exception]::new("Graph request failed ($Status $Code): $Message")
    $ex.Data['AdGraphError'] = $true
    $ex.Data['Status'] = $Status
    $ex.Data['Code'] = $Code
    $ex.Data['GraphMessage'] = $Message
    $ex.Data['RequestId'] = $RequestId
    $ex.Data['Uri'] = $Uri
    return $ex
}

function Test-AdGraphRequestAllowed {
    <#
      Returns [pscustomobject]@{ Allowed; Reason }. Pure function so it can be unit tested.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [bool]$AllowDiagnosticsPost = $false
    )
    $deny = { param($r) [pscustomobject]@{ Allowed = $false; Reason = $r } }

    $parsed = $null
    if (-not [uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed)) { return & $deny 'URI is not absolute.' }
    if ($parsed.Scheme -ne 'https') { return & $deny 'Only https is allowed.' }
    if ($parsed.Host -ne $script:AdGraphHost) { return & $deny "Host '$($parsed.Host)' is not Microsoft Graph." }
    if (-not $parsed.IsDefaultPort) { return & $deny 'Non-default port.' }
    if ($parsed.UserInfo) { return & $deny 'User info in URI is not allowed.' }

    $m = $Method.ToUpperInvariant()
    if ($m -eq 'GET') { return [pscustomobject]@{ Allowed = $true; Reason = 'GET' } }

    if ($m -eq 'POST') {
        if (-not $AllowDiagnosticsPost) { return & $deny 'POST is blocked (diagnostics exception disabled in settings).' }
        if ($parsed.Query) { return & $deny 'POST exception does not allow a query string.' }
        $path = $parsed.AbsolutePath
        if ($Uri -match '(?i)%2e|%2f|%5c|\.\.') { return & $deny 'Encoded or relative path segments are not allowed.' }
        foreach ($ex in $script:AdApprovedPostExceptions) {
            if ($path -cmatch $ex.Pattern) { return [pscustomobject]@{ Allowed = $true; Reason = "Approved exception: $($ex.Name)" } }
        }
        return & $deny 'POST to this endpoint is not an approved read-only exception.'
    }
    return & $deny "HTTP method $m is not allowed (read-only app)."
}

function Assert-AdGraphRequestAllowed {
    param([string]$Method, [string]$Uri, [bool]$AllowDiagnosticsPost)
    $check = Test-AdGraphRequestAllowed -Method $Method -Uri $Uri -AllowDiagnosticsPost $AllowDiagnosticsPost
    if (-not $check.Allowed) {
        Write-AdLog -Level WARN -Message "Blocked Graph request: $Method ($($check.Reason))"
        $ex = [System.InvalidOperationException]::new("Read-only policy blocked this request: $($check.Reason)")
        $ex.Data['AdReadOnlyViolation'] = $true
        throw $ex
    }
}

function Get-AdRetryDelaySeconds {
    param($Response, [int]$Attempt)
    $retryAfter = $null
    if ($Response -and $Response.Headers) {
        $h = $Response.Headers['Retry-After']
        if ($h) { $retryAfter = @($h)[0] }
    }
    $seconds = 0
    if ($retryAfter -and [int]::TryParse([string]$retryAfter, [ref]$seconds)) { return [math]::Min([math]::Max($seconds, 1), 120) }
    return [math]::Min([math]::Pow(2, $Attempt), 60) + (Get-Random -Minimum 0 -Maximum 1000) / 1000
}

function Invoke-AdGraphRequest {
    [CmdletBinding()]
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][scriptblock]$TokenProvider,
        [int]$MaxRetries = 5,
        [bool]$AllowDiagnosticsPost = $false
    )
    Assert-AdGraphRequestAllowed -Method $Method -Uri $Uri -AllowDiagnosticsPost $AllowDiagnosticsPost
    $logUri = ([uri]$Uri).AbsolutePath

    for ($attempt = 0; ; $attempt++) {
        $token = & $TokenProvider
        if (-not $token) { throw (New-AdGraphException -Status 401 -Code 'notSignedIn' -Message 'No valid access token. Sign in again.' -Uri $logUri) }
        $headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
        $resp = $null
        try {
            $params = @{
                Uri = $Uri; Method = $Method; Headers = $headers; SkipHttpErrorCheck = $true
                MaximumRedirection = 0; TimeoutSec = 100; ErrorAction = 'Stop'
            }
            if ($Method -eq 'POST') { $params.ContentType = 'application/json'; $params.Body = '' }
            $resp = Invoke-WebRequest @params
        }
        catch {
            if ($attempt -lt $MaxRetries) {
                $delay = Get-AdRetryDelaySeconds -Response $null -Attempt $attempt
                Write-AdLog -Level WARN -Message "Network error on $logUri; retry $($attempt + 1)/$MaxRetries in $([int]$delay)s."
                Start-Sleep -Milliseconds ([int]($delay * 1000))
                continue
            }
            throw (New-AdGraphException -Status 0 -Code 'networkError' -Message $_.Exception.Message -Uri $logUri)
        }

        $status = [int]$resp.StatusCode
        if ($status -ge 200 -and $status -lt 300) {
            if ([string]::IsNullOrWhiteSpace($resp.Content)) { return $null }
            return ($resp.Content | ConvertFrom-Json -Depth 64)
        }
        if ($status -in 429, 500, 502, 503, 504 -and $attempt -lt $MaxRetries) {
            $delay = Get-AdRetryDelaySeconds -Response $resp -Attempt $attempt
            Write-AdLog -Level WARN -Message "Graph returned $status for $logUri; retry $($attempt + 1)/$MaxRetries in $([int]$delay)s."
            Start-Sleep -Milliseconds ([int]($delay * 1000))
            continue
        }

        $code = 'httpError'; $message = "HTTP $status"; $requestId = $null
        try {
            $err = $resp.Content | ConvertFrom-Json -Depth 10
            if ($err.error) {
                $code = [string]$err.error.code
                $message = [string]$err.error.message
                if ($err.error.innerError) { $requestId = [string]$err.error.innerError.'request-id' }
            }
        }
        catch { }
        # Graph's message helps diagnose 400s; Write-AdLog scrubs tokens and UPNs, and it is truncated.
        $short = if ($message.Length -gt 200) { $message.Substring(0, 200) + '...' } else { $message }
        Write-AdLog -Level WARN -Message "Graph $status $code on $logUri : $short$(if ($requestId) { " (request-id $requestId)" })"
        throw (New-AdGraphException -Status $status -Code $code -Message $message -RequestId $requestId -Uri $logUri)
    }
}

function Get-AdGraphCollection {
    <# Follows @odata.nextLink until exhausted. Every page goes through Invoke-AdGraphRequest. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][scriptblock]$TokenProvider,
        [int]$MaxRetries = 5,
        [int]$MaxPages = 1000,
        [scriptblock]$OnPage
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $page = 0
    while ($next) {
        $page++
        if ($page -gt $MaxPages) {
            Write-AdLog -Level WARN -Message "Stopped paging after $MaxPages pages."
            break
        }
        $resp = Invoke-AdGraphRequest -Method GET -Uri $next -TokenProvider $TokenProvider -MaxRetries $MaxRetries
        if ($null -ne $resp -and $resp.PSObject.Properties['value']) {
            foreach ($v in @($resp.value)) { if ($null -ne $v) { $items.Add($v) } }
        }
        if ($OnPage) { & $OnPage $page $items.Count }
        $next = if ($null -ne $resp -and $resp.PSObject.Properties['@odata.nextLink']) { [string]$resp.'@odata.nextLink' } else { $null }
    }
    if ($items.Count -eq 0) { return @() }   # emits nothing, so @(...) at the call site is empty
    return , $items.ToArray()
}

function Get-AdGraphErrorInfo {
    <# Normalises an error record into a small, UI-safe object. #>
    param($ErrorRecord)
    $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    if ($ex.Data['AdGraphError']) {
        return [pscustomobject]@{
            status = [int]$ex.Data['Status']; code = [string]$ex.Data['Code']
            message = Protect-AdLogText ([string]$ex.Data['GraphMessage']); requestId = [string]$ex.Data['RequestId']
        }
    }
    if ($ex.Data['AdReadOnlyViolation']) { return [pscustomobject]@{ status = 0; code = 'readOnlyPolicy'; message = $ex.Message; requestId = $null } }
    return [pscustomobject]@{ status = 0; code = 'error'; message = Protect-AdLogText $ex.Message; requestId = $null }
}
