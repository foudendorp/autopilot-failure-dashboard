#Requires -Version 7.4
<#
.SYNOPSIS
    Starts the local Autopilot Dashboard on http://127.0.0.1 (never exposed to the network).

.EXAMPLE
    ./Start-AutopilotDashboard.ps1

.EXAMPLE
    ./Start-AutopilotDashboard.ps1 -Demo       # fictional data, no tenant needed

.PARAMETER Demo
    Load fictional demo data at startup.
.PARAMETER Port
    Override the port from config\settings.json.
.PARAMETER NoBrowser
    Don't open the default browser.
.PARAMETER ConfigPath
    Use another settings file instead of config\settings.json.
.PARAMETER InstallDependencies
    Install the Pode module for the current user if it is missing (from the PowerShell Gallery).
#>
[CmdletBinding()]
param(
    [switch]$Demo,
    [ValidateRange(1024, 65535)][int]$Port,
    [switch]$NoBrowser,
    [string]$ConfigPath,
    [switch]$InstallDependencies
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0

if (-not $IsWindows) { throw 'This app runs on Windows (it uses tar.exe and Get-WinEvent to parse diagnostics).' }
if ($PSVersionTable.PSVersion -lt [version]'7.4') { throw "PowerShell 7.4 or later is required (7.6 recommended). You are running $($PSVersionTable.PSVersion)." }

$root = $PSScriptRoot

# --- Dependencies --------------------------------------------------------------------------
$minPode = [version]'2.10.0'
$pode = Get-Module -ListAvailable -Name Pode | Where-Object Version -GE $minPode | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pode) {
    if ($InstallDependencies) {
        Write-Host "Installing Pode $minPode+ for the current user from the PowerShell Gallery..."
        Install-PSResource -Name Pode -Scope CurrentUser -TrustRepository -Quiet
        $pode = Get-Module -ListAvailable -Name Pode | Where-Object Version -GE $minPode | Sort-Object Version -Descending | Select-Object -First 1
    }
    if (-not $pode) {
        throw "The Pode module ($minPode or later) is required. Install it with:`n    Install-PSResource -Name Pode -Scope CurrentUser`nor run ./Start-AutopilotDashboard.ps1 -InstallDependencies"
    }
}
Import-Module $pode.Path -Force
Import-Module (Join-Path $root 'src\AutopilotDashboard.psm1') -Force

# --- Configuration -------------------------------------------------------------------------
$configPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $root 'config\settings.json' }
if (-not $ConfigPath -and -not (Test-Path -LiteralPath $configPath)) {
    Copy-Item -LiteralPath (Join-Path $root 'config\settings.example.json') -Destination $configPath
    Write-AdLog -Level WARN -Message 'Created config\settings.json from the example. Set authMode, tenantId and clientId to sign in (see README). Demo mode works without them.'
}
$config = Get-AdConfig -Path $configPath
if ($Port) { $config.port = $Port }
if (-not $config.isConfigured) {
    Write-AdLog -Level WARN -Message 'Sign-in is disabled: set tenantId and clientId (own app registration) or "authMode": "graphCli" in config\settings.json. Demo mode is available.'
}
else {
    Write-AdLog -Message "Sign-in app: $($config.signInApp). Redirect URI: $(Get-AdRedirectUri $config)"
}

$rules = Import-AdRules -Path (Join-Path $root 'rules.json')
Write-AdLog -Message "Loaded $($rules.Count) analysis rules from rules.json."

$state = New-AdAppState -Config $config -RootPath $root -Rules $rules
if ($Demo) { Set-AdDemoData -AppState $state }

. (Join-Path $root 'src\Server.ps1')
Start-AdDashboardServer -AppState $state -OpenBrowser:([bool]($config.openBrowser -and -not $NoBrowser))
