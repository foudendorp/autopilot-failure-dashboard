# Pipeline diagnostics: where do rows go between Graph and the screen?
# Output contains counts, IDs, enum values, tenant ID and scope names only: never tokens, user
# names, device names or serial numbers.

function Get-AdPipelineDiagnostics {
    param([Parameter(Mandatory)][hashtable]$AppState)
    $ds = $AppState.Dataset
    $model = $AppState.Model
    $auth = $AppState.Auth
    $requested = @(Get-AdScopes $AppState.Config)
    $granted = @(([string]$auth.GrantedScopes).Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
    # Token responses list Graph scopes with the resource prefix; OIDC scopes may be omitted.
    # Only meaningful with a token: without one, nothing has been granted yet.
    $missing = @(if ($auth.Status -eq 'signedIn') { $requested | Where-Object { $_ -like 'https://*' -and $_ -notin $granted } })

    $deployments = @(if ($model) { $model.deployments })
    $statusCounts = @($deployments | Group-Object { $_.status } | Sort-Object Name | ForEach-Object { [ordered]@{ status = $_.Name; count = $_.Count } })
    $stats = if ($ds -and $ds.Contains('stats')) { $ds.stats } else { $null }
    $rawStates = @()
    if ($stats -and $stats.rawDeploymentStates) {
        $rawStates = @(foreach ($k in $stats.rawDeploymentStates.Keys) {
                [ordered]@{
                    raw      = $k
                    count    = $stats.rawDeploymentStates[$k]
                    mappedTo = Get-AdStatus ([pscustomobject]@{ deploymentState = $(if ($k -eq '(empty)') { $null } else { $k }) })
                }
            })
    }

    [ordered]@{
        generatedUtc = [datetime]::UtcNow.ToString('o')
        mode         = if ($ds) { $ds.mode } else { $null }
        refresh      = [ordered]@{
            running       = [bool]$AppState.Refresh.running
            lastStarted   = $AppState.Refresh.startedUtc
            lastFinished  = $AppState.Refresh.finishedUtc
            lastError     = $AppState.Refresh.error
            dataFrom      = if ($ds) { $ds.refreshedUtc } else { $null }
            # A failed refresh keeps the previous data: make that visible.
            showingOlderData = [bool]($AppState.Refresh.error -and $ds)
            rangeFrom     = if ($ds) { $ds.from } else { $null }
            rangeTo       = if ($ds) { $ds.to } else { $null }
        }
        auth         = [ordered]@{
            status          = $auth.Status
            signInApp       = $AppState.Config.signInApp
            authority       = $AppState.Config.authority
            configuredTenant = if ($AppState.Config.tenantId) { $AppState.Config.tenantId } else { '(none: tenant of the signed-in account)' }
            tenantId        = if ($auth.Account) { $auth.Account.tenantId } else { $null }
            requestedScopes = $requested
            grantedScopes   = $granted
            missingScopes   = $missing
        }
        graph        = [ordered]@{
            endpoint        = if ($stats) { $stats.endpoint } else { $null }
            pages           = if ($stats) { $stats.pages } else { $null }
            rawRows         = if ($stats) { $stats.rawRows } else { $null }
            excludedByDate  = if ($stats) { $stats.excludedByDate } else { $null }
            rowsWithoutDate = if ($stats) { $stats.rowsWithoutDate } else { $null }
            keptRows        = if ($stats) { $stats.keptRows } else { $null }
        }
        processing   = [ordered]@{
            modelRows    = $deployments.Count
            statusCounts = $statusCounts
            rawStates    = $rawStates
            unknownStates = @($rawStates | Where-Object { $_.mappedTo -eq 'Not available' -and $_.raw -ne '(empty)' } | ForEach-Object { $_.raw })
        }
        errors       = @(if ($ds) { @($ds.sources) | Where-Object { $_.status -notin 'ok', 'demo', 'skipped' } | ForEach-Object { [ordered]@{ source = $_.name; status = $_.status; message = Protect-AdLogText $_.message } } })
        rulesError   = $AppState.RulesError
    }
}

function Find-AdPipelineRow {
    <#
      Looks a deployment up in the RAW Graph rows (before the date range) by event ID, serial number,
      device name or Intune device ID, and says where it ends up. Returns no personal data.
    #>
    param([Parameter(Mandatory)][hashtable]$AppState, [Parameter(Mandatory)][string]$Query)
    $q = $Query.Trim()
    $result = [ordered]@{ query = '(not echoed)'; searchedRows = 0; matches = @(); note = '' }
    $ds = $AppState.Dataset
    if (-not $ds -or $q.Length -lt 3) { $result.note = if (-not $ds) { 'No data loaded.' } else { 'Enter at least 3 characters.' }; return $result }
    $raw = @(if ($ds.Contains('rawEvents') -and $ds.rawEvents) { $ds.rawEvents } else { $ds.events })
    $result.searchedRows = $raw.Count
    $keptIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($ds.events | ForEach-Object { [string](Get-AdProp $_ 'id') }))
    $modelIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($(if ($AppState.Model) { $AppState.Model.deployments | ForEach-Object { [string]$_.id } })))
    $result.matches = @(foreach ($ev in $raw) {
            $fields = [ordered]@{
                'event ID' = [string](Get-AdProp $ev 'id'); 'serial number' = [string](Get-AdProp $ev 'deviceSerialNumber')
                'device name' = [string](Get-AdProp $ev 'managedDeviceName'); 'Intune device ID' = [string](Get-AdProp $ev 'deviceId')
            }
            $on = @($fields.Keys | Where-Object { $fields[$_] -and $fields[$_].Equals($q, [StringComparison]::OrdinalIgnoreCase) })
            if (-not $on) { continue }
            $id = $fields['event ID']
            $verdict = if (-not $keptIds.Contains($id)) { 'outsideRange' } elseif ($modelIds.Contains($id)) { 'shown' } else { 'droppedInProcessing' }
            [ordered]@{
                eventId            = $id
                matchedOn          = $on -join ', '
                rawDeploymentState = Get-AdProp $ev 'deploymentState'
                mappedStatus       = Get-AdStatus $ev
                dates              = [ordered]@{
                    deploymentStart = Get-AdProp $ev 'deploymentStartDateTime'; enrollmentStart = Get-AdProp $ev 'enrollmentStartDateTime'
                    event = Get-AdProp $ev 'eventDateTime'; deploymentEnd = Get-AdProp $ev 'deploymentEndDateTime'
                }
                verdict            = $verdict
                explanation        = switch ($verdict) {
                    'shown' { 'Retrieved and processed. If you can''t see it, check the date range and filters in the browser (see "Rows after browser filters").' }
                    'outsideRange' { 'Retrieved from Graph, but none of its dates falls inside the refreshed date range. Widen the range and refresh.' }
                    default { 'Retrieved and inside the range, but missing after processing. This is a bug: please report it.' }
                }
            }
        })
    if (-not $result.matches) { $result.note = "Not found in the $($raw.Count) rows Graph returned in the last refresh. Check the tenant and the account you signed in with." }
    return $result
}
