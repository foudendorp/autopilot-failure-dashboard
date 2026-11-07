# Operational logging. Writes to the console only, never to disk, and scrubs anything
# that looks like a token, an authorization code or a user principal name.

function Protect-AdLogText {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text
    # JWTs (access / id tokens)
    $t = [regex]::Replace($t, 'eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*', '[redacted-token]')
    # key=value or "key": "value" pairs for sensitive OAuth parameters
    $t = [regex]::Replace($t, '(?i)\b(access_token|refresh_token|id_token|code|code_verifier|client_secret|assertion|sig|state|nonce)(["'']?\s*[:=]\s*["'']?)[^&\s"'',}]+', '$1$2[redacted]')
    $t = [regex]::Replace($t, '(?i)\b(Bearer)\s+[A-Za-z0-9\-\._~\+/]+=*', '$1 [redacted]')
    # e-mail addresses / UPNs
    $t = [regex]::Replace($t, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '[redacted-upn]')
    return $t
}

function Write-AdLog {
    [CmdletBinding()]
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO',
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    if ($Level -eq 'DEBUG' -and -not $env:AUTOPILOT_DASHBOARD_DEBUG) { return }
    $line = '{0:yyyy-MM-dd HH:mm:ss}Z [{1}] {2}' -f [datetime]::UtcNow, $Level, (Protect-AdLogText $Message)
    [Console]::WriteLine($line)
}
