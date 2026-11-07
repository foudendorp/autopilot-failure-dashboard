# Local configuration (config\settings.json). Holds tenant ID, client ID and limits only.
# Never put secrets here: the app uses interactive delegated sign-in without client secrets.

# Microsoft's first-party public client used by Microsoft Graph PowerShell (Connect-MgGraph).
# Its only loopback redirect URI is http://localhost (port ignored), so authMode 'graphCli' signs in
# through http://localhost:<port> instead of http://127.0.0.1:<port>/auth/callback.
$script:AdGraphCliClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

function Get-AdDefaultConfig {
    [ordered]@{
        authMode                      = 'custom'
        tenantId                      = ''
        clientId                      = ''
        port                          = 8765
        defaultDays                   = 30
        maxDays                       = 90
        maxUploadMB                   = 250
        maxExtractedMB                = 2048
        maxArchiveEntries             = 10000
        maxProfileLookups             = 300
        tryPolicyStatusDetails        = $false
        policyDetailsForAllEvents     = $false
        graphMaxRetries               = 5
        allowDiagnosticsDownloadPost  = $true
        requestConfigurationReadScope = $true
        useCommunityDiagnosticsScript = $false
        openBrowser                   = $true
    }
}

function Test-AdGuid {
    param([AllowNull()][string]$Value)
    $g = [guid]::Empty
    return ($null -ne $Value -and [guid]::TryParse($Value, [ref]$g))
}

function Get-AdConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $config = Get-AdDefaultConfig
    if (Test-Path -LiteralPath $Path) {
        $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        foreach ($key in @($raw.Keys)) {
            if ($key.StartsWith('_')) { continue }   # comments
            if ($config.Contains($key)) { $config[$key] = $raw[$key] }
            else { Write-AdLog -Level WARN -Message "Unknown setting '$key' in settings.json ignored." }
        }
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    $config.authMode = ([string]$config.authMode).Trim()
    if ($config.authMode -notin 'custom', 'graphCli') { $errors.Add("authMode must be 'custom' (your own app registration) or 'graphCli' (Microsoft Graph Command Line Tools).") }
    if ($config.authMode -eq 'graphCli') {
        if ($config.clientId -and $config.clientId -ne $script:AdGraphCliClientId) {
            Write-AdLog -Level WARN -Message "authMode is 'graphCli': clientId in settings.json is ignored and the Microsoft Graph Command Line Tools client ID is used."
        }
        $config.clientId = $script:AdGraphCliClientId
    }
    $tenant = [string]$config.tenantId
    if ($tenant -and -not (Test-AdGuid $tenant) -and $tenant -notmatch '^[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)+$') {
        $errors.Add('tenantId must be a GUID or a verified domain name (for example contoso.onmicrosoft.com).')
    }
    if ($tenant -in @('common', 'organizations', 'consumers')) {
        $errors.Add('tenantId must be your specific tenant, not a multi-tenant alias.')
    }
    if ($config.clientId -and -not (Test-AdGuid ([string]$config.clientId))) { $errors.Add('clientId must be a GUID.') }
    $port = [int]$config.port
    if ($port -lt 1024 -or $port -gt 65535) { $errors.Add('port must be between 1024 and 65535.') }
    foreach ($n in 'defaultDays', 'maxDays', 'maxUploadMB', 'maxExtractedMB', 'maxArchiveEntries', 'maxProfileLookups', 'graphMaxRetries') {
        if ([int]$config[$n] -lt 1) { $errors.Add("$n must be a positive number.") }
    }
    if ($errors.Count) { throw ('Invalid settings.json: ' + ($errors -join ' ')) }

    $config.port = $port
    if ($config.authMode -eq 'graphCli') {
        # Tenant is optional: without it the 'organizations' authority is used and the tenant is
        # taken from the signed-in account.
        $config.authority = if ($tenant) { $tenant } else { 'organizations' }
        $config.signInApp = 'Microsoft Graph Command Line Tools (Microsoft first-party app)'
        $config.isConfigured = $true
    }
    else {
        $config.authority = $tenant
        $config.signInApp = 'Your own app registration'
        $config.isConfigured = [bool]($config.tenantId -and $config.clientId)
    }
    return $config
}
