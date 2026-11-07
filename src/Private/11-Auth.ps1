# Interactive, delegated Microsoft Entra sign-in: OAuth 2.0 authorization code flow with PKCE
# for a public client (no client secret, no certificate). The redirect URI is the local app itself:
#   authMode custom   -> http://127.0.0.1:<port>/auth/callback (your own app registration)
#   authMode graphCli -> http://localhost:<port> (Microsoft Graph Command Line Tools, first-party)
# Tokens live only in the in-memory app state.

$script:AdLoginHost = 'https://login.microsoftonline.com'

function ConvertTo-AdBase64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-AdRandomToken {
    param([int]$Bytes = 32)
    ConvertTo-AdBase64Url ([System.Security.Cryptography.RandomNumberGenerator]::GetBytes($Bytes))
}

function New-AdPkcePair {
    $verifier = New-AdRandomToken -Bytes 48
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($verifier))
    [pscustomobject]@{ Verifier = $verifier; Challenge = (ConvertTo-AdBase64Url $hash) }
}

function Test-AdFixedTimeEquals {
    param([string]$A, [string]$B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    $ba = [System.Text.Encoding]::UTF8.GetBytes($A)
    $bb = [System.Text.Encoding]::UTF8.GetBytes($B)
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($ba, $bb)
}

function Get-AdScopes {
    param([Parameter(Mandatory)]$Config)
    $scopes = @(
        'openid', 'profile', 'offline_access',
        'https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All',
        'https://graph.microsoft.com/DeviceManagementServiceConfig.Read.All'
    )
    if ($Config.requestConfigurationReadScope) { $scopes += 'https://graph.microsoft.com/DeviceManagementConfiguration.Read.All' }
    return $scopes
}

function Get-AdRedirectUri {
    param([Parameter(Mandatory)]$Config)
    if ($Config.authMode -eq 'graphCli') { return "http://localhost:$($Config.port)" }
    "http://127.0.0.1:$($Config.port)/auth/callback"
}

function New-AdAuthorizationRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    if (-not $Config.isConfigured) { throw 'Set tenantId and clientId in config\settings.json, or set "authMode": "graphCli", before signing in.' }
    $pkce = New-AdPkcePair
    $state = New-AdRandomToken
    $nonce = New-AdRandomToken
    $query = [ordered]@{
        client_id             = $Config.clientId
        response_type         = 'code'
        redirect_uri          = Get-AdRedirectUri $Config
        response_mode         = 'query'
        scope                 = (Get-AdScopes $Config) -join ' '
        state                 = $state
        nonce                 = $nonce
        code_challenge        = $pkce.Challenge
        code_challenge_method = 'S256'
        prompt                = 'select_account'
    }
    $qs = ($query.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, [uri]::EscapeDataString([string]$_.Value) }) -join '&'
    [pscustomobject]@{
        Url        = "$script:AdLoginHost/$([uri]::EscapeDataString($Config.authority))/oauth2/v2.0/authorize?$qs"
        State      = $state
        Nonce      = $nonce
        Verifier   = $pkce.Verifier
        CreatedUtc = [datetime]::UtcNow
    }
}

function ConvertFrom-AdJwtPayload {
    <# Decodes JWT claims. The id_token is received directly from the token endpoint over TLS
       (back channel), so per OpenID Connect Core 3.1.3.7 signature validation is not required
       for display purposes. Claims are only used to show account/tenant and to check tid/aud/nonce. #>
    param([Parameter(Mandatory)][string]$Jwt)
    $parts = $Jwt.Split('.')
    if ($parts.Count -lt 2) { throw 'Malformed token.' }
    $p = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}

function Invoke-AdTokenRequest {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][hashtable]$Body)
    $uri = "$script:AdLoginHost/$([uri]::EscapeDataString($Config.authority))/oauth2/v2.0/token"
    $Body.client_id = $Config.clientId
    $resp = Invoke-WebRequest -Uri $uri -Method POST -Body $Body -ContentType 'application/x-www-form-urlencoded' -SkipHttpErrorCheck -TimeoutSec 60 -MaximumRedirection 0
    $json = $null
    try { $json = $resp.Content | ConvertFrom-Json } catch { }
    if ([int]$resp.StatusCode -ne 200 -or -not $json -or -not $json.access_token) {
        $code = if ($json -and $json.error) { [string]$json.error } else { "http_$([int]$resp.StatusCode)" }
        $desc = if ($json -and $json.error_description) { ([string]$json.error_description -split "`r?`n")[0] } else { 'Token request failed.' }
        $ex = [System.Exception]::new("Sign-in failed: $code. $(Protect-AdLogText $desc)")
        $ex.Data['AuthError'] = $code
        throw $ex
    }
    return $json
}

function Set-AdTokenResult {
    param([Parameter(Mandatory)][hashtable]$AppState, [Parameter(Mandatory)]$TokenResponse, [string]$ExpectedNonce)
    $auth = $AppState.Auth
    $claims = $null
    if ($TokenResponse.PSObject.Properties['id_token'] -and $TokenResponse.id_token) {
        $claims = ConvertFrom-AdJwtPayload $TokenResponse.id_token
        if ($claims.aud -ne $AppState.Config.clientId) { throw 'Sign-in rejected: id_token audience does not match the configured client ID.' }
        if ($ExpectedNonce -and $claims.nonce -ne $ExpectedNonce) { throw 'Sign-in rejected: nonce mismatch.' }
        if ((Test-AdGuid $AppState.Config.tenantId) -and $claims.tid -ne $AppState.Config.tenantId) {
            throw 'Sign-in rejected: the account belongs to a different tenant than the one in settings.json.'
        }
        $upn = if ($claims.PSObject.Properties['preferred_username']) { [string]$claims.preferred_username } else { '' }
        $auth.Account = [ordered]@{
            name     = [string]$claims.name
            upn      = $upn
            tenantId = [string]$claims.tid
            domain   = if ($upn -match '@(.+)$') { $Matches[1] } else { '' }
        }
    }
    $auth.AccessToken = [string]$TokenResponse.access_token
    if ($TokenResponse.PSObject.Properties['refresh_token'] -and $TokenResponse.refresh_token) { $auth.RefreshToken = [string]$TokenResponse.refresh_token }
    $auth.ExpiresUtc = [datetime]::UtcNow.AddSeconds([int]$TokenResponse.expires_in)
    $auth.GrantedScopes = [string]$TokenResponse.scope
    $auth.Status = 'signedIn'
    $auth.Message = ''
}

function Complete-AdSignIn {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$AppState, [string]$Code, [string]$State)
    $pending = $AppState.Auth.Pending
    $AppState.Auth.Pending = $null   # single use
    if (-not $pending) { throw 'No sign-in is in progress. Start again from the dashboard.' }
    if (-not (Test-AdFixedTimeEquals $State $pending.State)) { throw 'Sign-in rejected: state mismatch (possible CSRF).' }
    if (([datetime]::UtcNow - $pending.CreatedUtc).TotalMinutes -gt 10) { throw 'Sign-in expired. Start again.' }
    if (-not $Code) { throw 'No authorization code returned.' }

    $token = Invoke-AdTokenRequest -Config $AppState.Config -Body @{
        grant_type    = 'authorization_code'
        code          = $Code
        redirect_uri  = Get-AdRedirectUri $AppState.Config
        code_verifier = $pending.Verifier
        scope         = (Get-AdScopes $AppState.Config) -join ' '
    }
    Set-AdTokenResult -AppState $AppState -TokenResponse $token -ExpectedNonce $pending.Nonce
    Write-AdLog -Message 'Sign-in completed.'
}

function Clear-AdSession {
    param([Parameter(Mandatory)][hashtable]$AppState, [string]$Status = 'signedOut', [string]$Message = '')
    $a = $AppState.Auth
    $a.AccessToken = $null; $a.RefreshToken = $null; $a.ExpiresUtc = $null
    $a.Account = $null; $a.Pending = $null; $a.GrantedScopes = $null
    $a.Status = $Status; $a.Message = $Message
}

function Get-AdAccessToken {
    <# Returns a valid access token, refreshing it (in memory) when it is about to expire.
       On refresh failure the session is cleared and marked expired. #>
    param([Parameter(Mandatory)][hashtable]$AppState)
    $lock = $AppState.AuthLock
    [System.Threading.Monitor]::Enter($lock)
    try {
        $a = $AppState.Auth
        if ($a.Status -ne 'signedIn' -or -not $a.AccessToken) { return $null }
        if ($a.ExpiresUtc -and $a.ExpiresUtc -gt [datetime]::UtcNow.AddMinutes(3)) { return $a.AccessToken }
        if (-not $a.RefreshToken) {
            Clear-AdSession -AppState $AppState -Status 'expired' -Message 'Your session expired. Sign in again.'
            return $null
        }
        try {
            $token = Invoke-AdTokenRequest -Config $AppState.Config -Body @{
                grant_type = 'refresh_token'; refresh_token = $a.RefreshToken; scope = (Get-AdScopes $AppState.Config) -join ' '
            }
            Set-AdTokenResult -AppState $AppState -TokenResponse $token
            Write-AdLog -Message 'Access token refreshed.'
            return $a.AccessToken
        }
        catch {
            Write-AdLog -Level WARN -Message "Token refresh failed: $($_.Exception.Message)"
            Clear-AdSession -AppState $AppState -Status 'expired' -Message 'Your session expired or was revoked. Sign in again.'
            return $null
        }
    }
    finally { [System.Threading.Monitor]::Exit($lock) }
}

function Get-AdAuthStatus {
    param([Parameter(Mandatory)][hashtable]$AppState)
    $a = $AppState.Auth
    [ordered]@{
        status        = $a.Status
        message       = $a.Message
        account       = $a.Account
        expiresUtc    = if ($a.ExpiresUtc) { $a.ExpiresUtc.ToString('o') } else { $null }
        grantedScopes = if ($a.GrantedScopes) { @(([string]$a.GrantedScopes).Split(' ') | Where-Object { $_ }) } else { @() }
        configured    = [bool]$AppState.Config.isConfigured
        redirectUri   = Get-AdRedirectUri $AppState.Config
        authMode      = $AppState.Config.authMode
        signInApp     = $AppState.Config.signInApp
    }
}

function Invoke-AdAuthCallback {
    <# Handles the redirect from Entra (?code&state or ?error). Never throws: failures are shown in the UI. #>
    param([Parameter(Mandatory)][hashtable]$AppState, [Parameter(Mandatory)]$Query)
    try {
        $err = [string]$Query['error']
        if ($err) {
            $desc = ([string]$Query['error_description'] -split "`r?`n")[0]
            $AppState.Auth.Pending = $null
            throw "Sign-in was not completed: $err. $desc"
        }
        Complete-AdSignIn -AppState $AppState -Code ([string]$Query['code']) -State ([string]$Query['state'])
        if ($AppState.Dataset -and $AppState.Dataset.mode -eq 'demo') { $AppState.Dataset = $null; $AppState.Model = $null; $AppState.Logs.Clear() }
    }
    catch {
        Clear-AdSession -AppState $AppState -Status 'signedOut' -Message (Protect-AdLogText $_.Exception.Message)
        Write-AdLog -Level WARN -Message "Sign-in failed: $($_.Exception.Message)"
    }
}