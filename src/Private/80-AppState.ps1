# In-memory application state shared by all Pode runspaces (a synchronized hashtable stored in
# Pode state). Nothing in here is ever written to disk.

function New-AdAppState {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$RootPath, [object[]]$Rules)
    $state = [hashtable]::Synchronized(@{})
    $state.Config = $Config
    $state.RootPath = $RootPath
    $state.ModulePath = Join-Path $RootPath 'src\AutopilotDashboard.psm1'
    $state.RulesPath = Join-Path $RootPath 'rules.json'
    $state.Rules = $Rules
    $state.RulesError = $null
    $state.Auth = [hashtable]::Synchronized(@{ Status = 'signedOut'; Message = ''; Account = $null; AccessToken = $null; RefreshToken = $null; ExpiresUtc = $null; Pending = $null; GrantedScopes = $null })
    $state.AuthLock = [object]::new()
    $state.DataLock = [object]::new()
    $state.Dataset = $null
    $state.Model = $null
    $state.Logs = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    $state.Refresh = [hashtable]::Synchronized(@{ running = $false; percent = 0; message = ''; error = $null; startedUtc = $null; finishedUtc = $null })
    $state.RefreshJob = $null
    $state.CsrfToken = New-AdRandomToken
    $state.AnonymizeKey = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $state.Anonymize = $false
    $state.Downloads = [hashtable]::Synchronized(@{})
    $state.Capability = $null
    return $state
}

function Update-AdModel {
    <# Rebuilds deployments + improvements from the current dataset, rules and log analyses. #>
    param([Parameter(Mandatory)][hashtable]$AppState)
    [System.Threading.Monitor]::Enter($AppState.DataLock)
    try {
        try { $AppState.Rules = Import-AdRules -Path $AppState.RulesPath; $AppState.RulesError = $null }
        catch {
            $AppState.RulesError = "rules.json could not be loaded; using the last valid rules. $($_.Exception.Message)"
            Write-AdLog -Level WARN -Message $AppState.RulesError
        }
        $logs = @($AppState.Logs.ToArray())
        $deployments = if ($AppState.Dataset) { ConvertTo-AdDeploymentModel -Dataset $AppState.Dataset -Rules $AppState.Rules -LogAnalyses $logs } else { @() }
        # Re-evaluate standalone log findings with the current rules.
        foreach ($l in $logs) { if ($l.status -ne 'error') { $l.findings = Find-AdRuleMatches -Evidence (Get-AdLogEvidence $l) -Rules $AppState.Rules } }
        $AppState.Model = [ordered]@{
            deployments  = $deployments
            improvements = Get-AdStructuralImprovements -Deployments $deployments
            builtUtc     = [datetime]::UtcNow.ToString('o')
        }
    }
    finally { [System.Threading.Monitor]::Exit($AppState.DataLock) }
}

function Get-AdDataPayload {
    param([Parameter(Mandatory)][hashtable]$AppState, [switch]$Raw)
    $ds = $AppState.Dataset
    $model = $AppState.Model
    $payload = [ordered]@{
        hasData      = [bool]$ds
        anonymized   = [bool]$AppState.Anonymize
        meta         = [ordered]@{
            mode = if ($ds) { $ds.mode } else { $null }
            refreshedUtc = if ($ds) { $ds.refreshedUtc } else { $null }
            from = if ($ds) { $ds.from } else { $null }
            to = if ($ds) { $ds.to } else { $null }
            sources = @(if ($ds) { $ds.sources })
            devicePrep = if ($ds) { $ds.devicePrep } else { $null }
            rulesError = $AppState.RulesError
            ruleCount = @($AppState.Rules).Count
            phases = Get-AdPhaseNames
        }
        # @(if ...) always yields a list: a bare `if` unrolls a one-item list into the item itself,
        # which the browser then receives as a JSON object instead of an array (empty dashboard).
        deployments  = @(if ($model) { $model.deployments })
        improvements = @(if ($model) { $model.improvements })
        logs         = @($AppState.Logs.ToArray())
    }
    if (-not $AppState.Anonymize -or $Raw) { return $payload }
    $sensitive = Get-AdSensitiveValues -Deployments $payload.deployments -LogAnalyses $payload.logs -Account $AppState.Auth.Account
    return Protect-AdPayload -Payload $payload -SensitiveValues $sensitive -Key $AppState.AnonymizeKey
}

function Get-AdDataJson {
    <# JSON for /api/data. Masks the serialized text directly (no extra round trip) when anonymizing. #>
    param([Parameter(Mandatory)][hashtable]$AppState)
    $payload = Get-AdDataPayload -AppState $AppState -Raw
    $json = $payload | ConvertTo-Json -Depth 30 -Compress
    if (-not $AppState.Anonymize) { return $json }
    $sensitive = Get-AdSensitiveValues -Deployments $payload.deployments -LogAnalyses $payload.logs -Account $AppState.Auth.Account
    return Protect-AdJson -Json $json -SensitiveValues $sensitive -Key $AppState.AnonymizeKey
}

function Start-AdRefreshJob {
    param([Parameter(Mandatory)][hashtable]$AppState, [Parameter(Mandatory)][datetime]$From, [Parameter(Mandatory)][datetime]$To)
    [System.Threading.Monitor]::Enter($AppState.DataLock)
    try {
        if ($AppState.Refresh.running) { throw 'A refresh is already running.' }
        if ($AppState.RefreshJob) {
            try { $AppState.RefreshJob.PS.Dispose() } catch { }
            $AppState.RefreshJob = $null
        }
        $AppState.Refresh.running = $true
        $AppState.Refresh.percent = 0
        $AppState.Refresh.message = 'Starting refresh'
        $AppState.Refresh.error = $null
        $AppState.Refresh.startedUtc = [datetime]::UtcNow.ToString('o')
        $AppState.Refresh.finishedUtc = $null
    }
    finally { [System.Threading.Monitor]::Exit($AppState.DataLock) }

    $ps = [powershell]::Create()
    $null = $ps.AddScript({
            param($AppState, $From, $To)
            try {
                Import-Module $AppState.ModulePath -Force
                $tokenProvider = { Get-AdAccessToken -AppState $AppState }.GetNewClosure()
                $progress = { param($p, $m) $AppState.Refresh.percent = [int]$p; $AppState.Refresh.message = [string]$m }.GetNewClosure()
                Write-AdLog -Message "Refresh started for $($From.ToString('yyyy-MM-dd')) .. $($To.ToString('yyyy-MM-dd'))."
                $ds = Invoke-AdDataRefresh -TokenProvider $tokenProvider -Config $AppState.Config -From $From -To $To -Progress $progress
                $AppState.Dataset = $ds
                $AppState.Logs.Clear()   # logs from a previous tenant/demo dataset no longer apply
                Update-AdModel -AppState $AppState
                $failed = @($ds.sources | Where-Object { $_.status -in 'error', 'forbidden', 'unsupported' })
                $AppState.Refresh.message = if ($failed) { "Completed with $($failed.Count) source(s) unavailable. See Data sources." } else { 'Completed' }
                Write-AdLog -Message "Refresh completed: $(@($ds.events).Count) events."
            }
            catch {
                $info = Get-AdGraphErrorInfo $_
                $AppState.Refresh.error = if ($info.status -eq 401) { 'Your session expired. Sign in again and retry.' } else { $info.message }
                Write-AdLog -Level ERROR -Message "Refresh failed: $($info.code)"
            }
            finally {
                $AppState.Refresh.running = $false
                $AppState.Refresh.percent = 100
                $AppState.Refresh.finishedUtc = [datetime]::UtcNow.ToString('o')
            }
        }).AddArgument($AppState).AddArgument($From).AddArgument($To)
    $AppState.RefreshJob = @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

function Set-AdDemoData {
    param([Parameter(Mandatory)][hashtable]$AppState)
    $AppState.Dataset = New-AdDemoDataset -Days ([int]$AppState.Config.defaultDays)
    $AppState.Logs.Clear()
    Update-AdModel -AppState $AppState
    Write-AdLog -Message 'Demo data loaded.'
}

function Add-AdLogAnalysis {
    param([Parameter(Mandatory)][hashtable]$AppState, [Parameter(Mandatory)]$Analysis)
    $null = $AppState.Logs.Add($Analysis)
    while ($AppState.Logs.Count -gt 25) { $AppState.Logs.RemoveAt(0) }   # bounded memory
    Update-AdModel -AppState $AppState
}

function New-AdDownloadTicket {
    param([Parameter(Mandatory)][hashtable]$AppState, [Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][string]$FileName, [Parameter(Mandatory)][string]$ContentType)
    foreach ($k in @($AppState.Downloads.Keys)) { if ($AppState.Downloads[$k].ExpiresUtc -lt [datetime]::UtcNow) { $AppState.Downloads.Remove($k) } }
    $ticket = New-AdRandomToken
    $AppState.Downloads[$ticket] = @{ Bytes = $Bytes; FileName = $FileName; ContentType = $ContentType; ExpiresUtc = [datetime]::UtcNow.AddMinutes(2) }
    return $ticket
}

function Get-AdDownload {
    param([Parameter(Mandatory)][hashtable]$AppState, [string]$Ticket)
    if (-not $Ticket -or -not $AppState.Downloads.ContainsKey($Ticket)) { return $null }
    $d = $AppState.Downloads[$Ticket]
    $AppState.Downloads.Remove($Ticket)   # one-time use
    if ($d.ExpiresUtc -lt [datetime]::UtcNow) { return $null }
    return $d
}
