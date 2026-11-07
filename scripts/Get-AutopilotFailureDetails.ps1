<#
.SYNOPSIS
    Read-only Microsoft Graph walkthrough for the latest failed Windows Autopilot deployment.

.DESCRIPTION
    Follows the "portal -> Graph -> dashboard" demo flow:
      1. Get all failed Autopilot deployments
      2. Take the latest failure and its serial number
      3. Check the Autopilot registration
      4. Check the device in Intune
      5. Find the Enrollment Status Page (ESP) used by the deployment
      6. Show the tracked app and its detection rule
      7. (Optional) Show recent Intune audit events

    The script only sends GET requests. It does not change anything in the tenant.

    Lessons from a real tenant (6 November 2026):
      - GET /deviceManagement/autopilotEvents/{id} returns HTTP 400.
        Use the list call and select the row locally.
      - /autopilotEvents/{id}/policyStatusDetails (and $expand=policyStatusDetails)
        returns HTTP 400, despite the documentation. App evidence is retrieved
        through the ESP and the app instead.
      - Graph beta endpoints can change. Test before every demo.

.PARAMETER AppIndex
    Index of the tracked app in the ESP to inspect. Default: 0 (the first app).

.PARAMETER EspName
    Name of the ESP to use when the failed event does not contain one.

.PARAMETER IncludeAuditEvents
    Also show Intune audit events from the last AuditDays days.

.PARAMETER AuditDays
    Number of days of audit events to show. Default: 7.

.EXAMPLE
    ./Get-AutopilotFailureDetails.ps1

.EXAMPLE
    ./Get-AutopilotFailureDetails.ps1 -EspName "ESP-Demo" -IncludeAuditEvents

.NOTES
    Requires PowerShell 7.4+ and the Microsoft.Graph.Authentication module:
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
    Uses Microsoft Graph beta endpoints. Use a test tenant and a test account.
    The output can contain device names, user names and serial numbers:
    mask it before sharing screenshots or logs.
#>

[CmdletBinding()]
param(
    [int]$AppIndex = 0,
    [string]$EspName,
    [switch]$IncludeAuditEvents,
    [ValidateRange(1, 30)]
    [int]$AuditDays = 7
)

$ErrorActionPreference = 'Stop'
$base = 'https://graph.microsoft.com/beta'

# Read-only delegated scopes
$scopes = @(
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementServiceConfig.Read.All'
    'DeviceManagementApps.Read.All'   # also covers auditEvents
)

function Invoke-GraphGetAll {
    <# GET with pagination through @odata.nextLink. Returns PSCustomObjects. #>
    param([Parameter(Mandatory)][string]$Uri)

    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        if (-not $next.StartsWith('https://graph.microsoft.com/')) {
            throw "Unexpected host in nextLink: $next"
        }
        $page = Invoke-MgGraphRequest -Method GET -Uri $next
        foreach ($item in @($page.value)) { $results.Add([pscustomobject]$item) }
        $next = $page.'@odata.nextLink'
    }
    # Items are written to the pipeline one by one.
    # Wrap the call in @(...) when you need an array, so one result stays a list.
    $results
}

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text ==" -ForegroundColor Cyan
}

Connect-MgGraph -Scopes $scopes -NoWelcome

# ---------------------------------------------------------------------------
# 1. Get all failed Autopilot deployments
#    Note: a server-side $filter on deploymentState works for this walkthrough.
#    A dashboard should get all events and filter locally, because a server-side
#    date filter can drop deployments the portal still shows.
# ---------------------------------------------------------------------------
Write-Step '1. Failed Autopilot deployments'
$uri = "$base/deviceManagement/autopilotEvents?`$filter=deploymentState eq 'failure'"
$events = @(Invoke-GraphGetAll -Uri $uri)

if ($events.Count -eq 0) {
    Write-Warning 'No failed Autopilot deployments found.'
    return
}

$events |
    Select-Object managedDeviceName, deviceSetupStatus, accountSetupStatus,
        deploymentDuration, enrollmentFailureDetails, eventDateTime |
    Format-Table -AutoSize

# ---------------------------------------------------------------------------
# 2. Take the latest failure and its serial number
#    Do NOT call /autopilotEvents/{id}: it returns HTTP 400. Select locally.
# ---------------------------------------------------------------------------
Write-Step '2. Latest failure'
$lastFailure = $events |
    Sort-Object { [datetime]$_.eventDateTime } -Descending |
    Select-Object -First 1

$ser = $lastFailure.deviceSerialNumber

$lastFailure |
    Format-List managedDeviceName, deviceSerialNumber, deploymentState,
        deviceSetupStatus, accountSetupStatus, enrollmentFailureDetails,
        windowsAutopilotDeploymentProfileDisplayName,
        windows10EnrollmentCompletionPageConfigurationDisplayName, eventDateTime

if (-not $ser) {
    Write-Warning 'The latest failure has no serial number. Steps 3 and 4 are skipped.'
}

# ---------------------------------------------------------------------------
# 3. Is the device registered correctly in Autopilot?
# ---------------------------------------------------------------------------
if ($ser) {
    Write-Step '3. Autopilot registration'
    $uri = "$base/deviceManagement/windowsAutopilotDeviceIdentities" +
        "?`$filter=contains(serialNumber,'$ser')"
    Invoke-GraphGetAll -Uri $uri |
        Select-Object serialNumber, groupTag, deploymentProfileAssignmentStatus,
            deploymentProfileAssignmentDetailedStatus, enrollmentState,
            lastContactedDateTime |
        Format-List
}

# ---------------------------------------------------------------------------
# 4. What is the device's state in Intune?
# ---------------------------------------------------------------------------
if ($ser) {
    Write-Step '4. Intune device'
    $uri = "$base/deviceManagement/managedDevices?`$filter=serialNumber eq '$ser'"
    Invoke-GraphGetAll -Uri $uri |
        Select-Object deviceName, userPrincipalName, joinType, enrollmentProfileName,
            complianceState, lastSyncDateTime |
        Format-List
}

# ---------------------------------------------------------------------------
# 5. Which ESP belonged to this deployment?
# ---------------------------------------------------------------------------
Write-Step '5. Enrollment Status Page'
if (-not $EspName) {
    $EspName = $lastFailure.windows10EnrollmentCompletionPageConfigurationDisplayName
}
if (-not $EspName) {
    Write-Warning 'The event has no ESP name. Run again with -EspName "<your ESP>".'
    return
}

$uri = "$base/deviceManagement/deviceEnrollmentConfigurations"
$esp = Invoke-GraphGetAll -Uri $uri |
    Where-Object { $_.displayName -eq $EspName } |
    Select-Object -First 1

if (-not $esp) {
    Write-Warning "No ESP named '$EspName' found."
    return
}

$esp |
    Select-Object displayName, installProgressTimeoutInMinutes, selectedMobileAppIds,
        allowDeviceUseOnInstallFailure, allowDeviceResetOnInstallFailure,
        allowLogCollectionOnInstallFailure |
    Format-List

# ---------------------------------------------------------------------------
# 6. Why was the app not detected? Show the tracked app and its rules.
#    policyStatusDetails is not used: it returns HTTP 400.
# ---------------------------------------------------------------------------
Write-Step '6. Tracked app and detection rule'
$appIds = @($esp.selectedMobileAppIds)
if ($appIds.Count -eq 0) {
    Write-Warning 'This ESP does not track any apps.'
}
elseif ($AppIndex -ge $appIds.Count) {
    Write-Warning "AppIndex $AppIndex is out of range. The ESP tracks $($appIds.Count) app(s)."
}
else {
    $appId = $appIds[$AppIndex]
    $app = Invoke-MgGraphRequest -Method GET -Uri "$base/deviceAppManagement/mobileApps/$appId"

    Write-Host "App:             $($app.displayName)"
    Write-Host "Install command: $($app.installCommandLine)"
    Write-Host ''
    Write-Host 'Rules:'
    @($app.rules) | ForEach-Object { [pscustomobject]$_ } | Format-List *
}

# ---------------------------------------------------------------------------
# 7. (Optional) Who changed what recently?
# ---------------------------------------------------------------------------
if ($IncludeAuditEvents) {
    Write-Step "7. Intune audit events (last $AuditDays days)"
    $since = (Get-Date).AddDays(-$AuditDays).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $uri = "$base/deviceManagement/auditEvents?`$filter=activityDateTime gt $since"
    Invoke-GraphGetAll -Uri $uri |
        Sort-Object { [datetime]$_.activityDateTime } -Descending |
        Select-Object activityDateTime, displayName, activityType, activityResult |
        Format-Table -AutoSize
}
