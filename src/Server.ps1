# Pode web server: routes, security middleware and static assets.
# Bound to 127.0.0.1 only. Every request is checked for the exact Host header (DNS-rebinding
# protection); every state-changing request needs a same-origin Origin header and the CSRF token.

function Start-AdDashboardServer {
    param([Parameter(Mandatory)][hashtable]$AppState, [switch]$OpenBrowser)

    $port = [int]$AppState.Config.port
    $root = $AppState.RootPath
    $browse = [bool]$OpenBrowser

    Start-PodeServer -RootPath $root -Threads 4 -Browse:$browse -DisableConsoleInput {
        Add-PodeEndpoint -Address 127.0.0.1 -Port $port -Protocol Http
        Import-PodeModule -Path $AppState.ModulePath
        Set-PodeState -Name 'App' -Value $AppState | Out-Null

        # ---------------------------------------------------------------- security middleware
        Add-PodeMiddleware -Name 'AdSecurity' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            $expectedHost = "127.0.0.1:$($app.Config.port)"
            Set-PodeHeader -Name 'Content-Security-Policy' -Value "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
            Set-PodeHeader -Name 'X-Content-Type-Options' -Value 'nosniff'
            Set-PodeHeader -Name 'X-Frame-Options' -Value 'DENY'
            Set-PodeHeader -Name 'Referrer-Policy' -Value 'no-referrer'
            Set-PodeHeader -Name 'Cross-Origin-Opener-Policy' -Value 'same-origin'
            Set-PodeHeader -Name 'Cross-Origin-Resource-Policy' -Value 'same-origin'
            Set-PodeHeader -Name 'Permissions-Policy' -Value 'camera=(), microphone=(), geolocation=(), usb=()'
            Set-PodeHeader -Name 'Cache-Control' -Value 'no-store'

            $hostHeader = Get-PodeHeader -Name 'Host'
            # authMode graphCli: Entra returns to http://localhost:<port>/?code&state. Only that exact
            # callback is accepted on the localhost name; the route then redirects to 127.0.0.1.
            $isLocalhostCallback = $app.Config.authMode -eq 'graphCli' -and $hostHeader -eq "localhost:$($app.Config.port)" -and
                $WebEvent.Path -eq '/' -and ([string]$WebEvent.Method).ToUpperInvariant() -eq 'GET' -and
                ($WebEvent.Query['state'] -or $WebEvent.Query['error'])
            if ($hostHeader -ne $expectedHost -and -not $isLocalhostCallback) {
                Write-AdLog -Level WARN -Message 'Rejected request with unexpected Host header.'
                Write-PodeTextResponse -Value 'Forbidden: unexpected Host header. Open the app at http://127.0.0.1.' -StatusCode 403
                return $false
            }
            $method = ([string]$WebEvent.Method).ToUpperInvariant()
            if ($method -notin 'GET', 'HEAD') {
                $origin = Get-PodeHeader -Name 'Origin'
                if ($origin -ne "http://$expectedHost") {
                    Write-AdLog -Level WARN -Message "Rejected $method with missing or foreign Origin."
                    Write-PodeJsonResponse -Value @{ error = 'Forbidden: cross-origin request.' } -StatusCode 403
                    return $false
                }
                $site = Get-PodeHeader -Name 'Sec-Fetch-Site'
                if ($site -and $site -ne 'same-origin') {
                    Write-PodeJsonResponse -Value @{ error = 'Forbidden: cross-site request.' } -StatusCode 403
                    return $false
                }
                if (-not (Test-AdFixedTimeEquals (Get-PodeHeader -Name 'X-CSRF-Token') $app.CsrfToken)) {
                    Write-AdLog -Level WARN -Message "Rejected $method with invalid CSRF token."
                    Write-PodeJsonResponse -Value @{ error = 'Forbidden: invalid CSRF token. Reload the page.' } -StatusCode 403
                    return $false
                }
            }
            return $true
        }

        # ---------------------------------------------------------------- static assets (whitelist)
        # '/' also receives the sign-in callback in authMode graphCli (redirect URI http://localhost:<port>).
        Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            if ($app.Config.authMode -eq 'graphCli' -and ($WebEvent.Query['state'] -or $WebEvent.Query['error'])) {
                Invoke-AdAuthCallback -AppState $app -Query $WebEvent.Query
                # Back to the canonical origin; the app itself only runs on 127.0.0.1.
                Move-PodeResponseUrl -Url "http://127.0.0.1:$($app.Config.port)/"
                return
            }
            Write-PodeFileResponse -Path (Join-Path $app.RootPath 'web/index.html')
        }
        $assets = @{
            '/assets/app.css'      = 'web/assets/app.css'
            '/assets/app.js'       = 'web/assets/app.js'
            '/assets/charts.js'    = 'web/assets/charts.js'
            '/assets/dom.js'       = 'web/assets/dom.js'
            '/assets/filters.js'   = 'web/assets/filters.js'
            '/assets/favicon.svg'  = 'web/assets/favicon.svg'
        }
        foreach ($route in $assets.Keys) {
            Add-PodeRoute -Method Get -Path $route -ArgumentList $assets[$route] -ScriptBlock {
                param($rel)
                $app = Get-PodeState -Name 'App'
                Write-PodeFileResponse -Path (Join-Path $app.RootPath $rel)
            }
        }

        # ---------------------------------------------------------------- bootstrap / auth
        Add-PodeRoute -Method Get -Path '/api/bootstrap' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            Write-PodeJsonResponse -Depth 10 -Value ([ordered]@{
                    csrfToken     = $app.CsrfToken
                    auth          = Get-AdAuthStatus -AppState $app
                    anonymize     = [bool]$app.Anonymize
                    defaultDays   = [int]$app.Config.defaultDays
                    maxDays       = [int]$app.Config.maxDays
                    maxUploadMB   = [int]$app.Config.maxUploadMB
                    hasData       = [bool]$app.Dataset
                    mode          = if ($app.Dataset) { $app.Dataset.mode } else { $null }
                    scopes        = Get-AdScopes $app.Config
                    postException = @(Get-AdApprovedPostExceptions | ForEach-Object { [ordered]@{ name = $_.Name; docs = $_.Docs } })
                    allowDiagPost = [bool]$app.Config.allowDiagnosticsDownloadPost
                    signInApp     = $app.Config.signInApp
                    redirectUri   = Get-AdRedirectUri $app.Config
                })
        }

        Add-PodeRoute -Method Get -Path '/api/auth/status' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            $null = Get-AdAccessToken -AppState $app   # refreshes or marks the session expired
            Write-PodeJsonResponse -Depth 10 -Value (Get-AdAuthStatus -AppState $app)
        }

        Add-PodeRoute -Method Post -Path '/api/auth/start' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            try {
                $req = New-AdAuthorizationRequest -Config $app.Config
                $app.Auth.Pending = $req
                Write-AdLog -Message 'Sign-in started.'
                Write-PodeJsonResponse -Value @{ url = $req.Url }
            }
            catch { Write-PodeJsonResponse -StatusCode 400 -Value @{ error = $_.Exception.Message } }
        }

        Add-PodeRoute -Method Get -Path '/auth/callback' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            Invoke-AdAuthCallback -AppState $app -Query $WebEvent.Query
            Move-PodeResponseUrl -Url '/'
        }

        Add-PodeRoute -Method Post -Path '/api/auth/signout' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            Clear-AdSession -AppState $app -Status 'signedOut' -Message 'Signed out. Tokens and tenant data were removed from memory.'
            if ($app.Dataset -and $app.Dataset.mode -eq 'tenant') { $app.Dataset = $null; $app.Model = $null; $app.Logs.Clear(); $app.Capability = $null }
            Write-AdLog -Message 'Signed out.'
            Write-PodeJsonResponse -Value @{ ok = $true }
        }

        # ---------------------------------------------------------------- data
        Add-PodeRoute -Method Post -Path '/api/refresh' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            try {
                if (-not (Get-AdAccessToken -AppState $app)) { Write-PodeJsonResponse -StatusCode 401 -Value @{ error = 'Not signed in or session expired. Sign in first.'; code = 'not_signed_in' }; return }
                $culture = [cultureinfo]::InvariantCulture
                $from = [datetime]::ParseExact([string]$WebEvent.Data.from, 'yyyy-MM-dd', $culture, 'AssumeUniversal,AdjustToUniversal')
                $to = [datetime]::ParseExact([string]$WebEvent.Data.to, 'yyyy-MM-dd', $culture, 'AssumeUniversal,AdjustToUniversal').AddDays(1).AddSeconds(-1)
                if ($to -lt $from) { throw 'The end date is before the start date.' }
                if (($to - $from).TotalDays -gt [int]$app.Config.maxDays + 1) { throw "The date range can't be longer than $($app.Config.maxDays) days (maxDays)." }
                Start-AdRefreshJob -AppState $app -From $from -To $to
                Write-PodeJsonResponse -Value @{ started = $true }
            }
            catch { Write-PodeJsonResponse -StatusCode 400 -Value @{ error = $_.Exception.Message } }
        }

        Add-PodeRoute -Method Get -Path '/api/refresh/status' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            Write-PodeJsonResponse -Value ([ordered]@{} + $app.Refresh)
        }

        Add-PodeRoute -Method Post -Path '/api/demo' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            try {
                if ($app.Auth.Status -eq 'signedIn') { throw 'Sign out before switching to demo mode, so tenant and demo data are never mixed.' }
                if ($app.Refresh.running) { throw 'A refresh is running.' }
                Set-AdDemoData -AppState $app
                Write-PodeJsonResponse -Value @{ ok = $true }
            }
            catch { Write-PodeJsonResponse -StatusCode 400 -Value @{ error = $_.Exception.Message } }
        }

        Add-PodeRoute -Method Post -Path '/api/data/clear' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            $app.Dataset = $null; $app.Model = $null; $app.Logs.Clear(); $app.Capability = $null
            Write-PodeJsonResponse -Value @{ ok = $true }
        }

        Add-PodeRoute -Method Get -Path '/api/data' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            try { Write-PodeTextResponse -Value (Get-AdDataJson -AppState $app) -ContentType 'application/json; charset=utf-8' }
            catch { Write-PodeJsonResponse -StatusCode 500 -Value @{ error = Protect-AdLogText $_.Exception.Message } }
        }

        # Pipeline diagnostics: counts, enum values, tenant ID and scope names only (no tokens, no personal data).
        Add-PodeRoute -Method Get -Path '/api/pipeline' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            try { Write-PodeJsonResponse -Depth 10 -Value (Get-AdPipelineDiagnostics -AppState $app) }
            catch { Write-PodeJsonResponse -StatusCode 500 -Value @{ error = Protect-AdLogText $_.Exception.Message } }
        }

        Add-PodeRoute -Method Post -Path '/api/pipeline/lookup' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            try { Write-PodeJsonResponse -Depth 10 -Value (Find-AdPipelineRow -AppState $app -Query ([string]$WebEvent.Data.query)) }
            catch { Write-PodeJsonResponse -StatusCode 400 -Value @{ error = Protect-AdLogText $_.Exception.Message } }
        }

        Add-PodeRoute -Method Get -Path '/api/rules' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            Write-PodeJsonResponse -Depth 10 -Value @{ rules = @($app.Rules); error = $app.RulesError }
        }

        Add-PodeRoute -Method Post -Path '/api/settings/anonymize' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            $app.Anonymize = [bool]$WebEvent.Data.enabled
            Write-PodeJsonResponse -Value @{ anonymize = $app.Anonymize }
        }

        # ---------------------------------------------------------------- export (after sensitivity warning)
        Add-PodeRoute -Method Post -Path '/api/export' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            try {
                if (-not [bool]$WebEvent.Data.acknowledged) { throw 'Confirm the sensitivity warning before exporting.' }
                $format = [string]$WebEvent.Data.format
                if ($format -notin 'csv', 'json') { throw 'Unknown export format.' }
                $ids = [System.Collections.Generic.HashSet[string]]::new([string[]]@($WebEvent.Data.ids | ForEach-Object { [string]$_ }))
                $payload = Get-AdDataPayload -AppState $app      # already anonymized when the toggle is on
                $deps = @($payload.deployments | Where-Object { $ids.Contains([string]$_.id) })
                $meta = @{ mode = $payload.meta.mode; from = $payload.meta.from; to = $payload.meta.to; refreshedUtc = $payload.meta.refreshedUtc; anonymized = [bool]$payload.anonymized; count = $deps.Count }
                $export = New-AdExport -Format $format -Deployments $deps -Improvements @($payload.improvements) -Meta $meta
                $ticket = New-AdDownloadTicket -AppState $app -Bytes $export.Bytes -FileName $export.FileName -ContentType $export.ContentType
                Write-AdLog -Message "Export created ($format, $($deps.Count) deployments, anonymized=$($meta.anonymized))."
                Write-PodeJsonResponse -Value @{ url = "/api/download/$ticket" }
            }
            catch { Write-PodeJsonResponse -StatusCode 400 -Value @{ error = $_.Exception.Message } }
        }

        Add-PodeRoute -Method Get -Path '/api/download/:ticket' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            $d = Get-AdDownload -AppState $app -Ticket $WebEvent.Parameters['ticket']
            if (-not $d) { Write-PodeTextResponse -Value 'This download link has expired. Start the export again.' -StatusCode 404; return }
            Set-PodeHeader -Name 'Content-Disposition' -Value ('attachment; filename="{0}"' -f ($d.FileName -replace '[^\w\.\-]', '_'))
            Write-PodeTextResponse -Bytes $d.Bytes -ContentType $d.ContentType
        }

        # ---------------------------------------------------------------- diagnostics
        Add-PodeRoute -Method Post -Path '/api/diagnostics/capability' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            try {
                if ($app.Dataset -and $app.Dataset.mode -eq 'demo') {
                    $app.Capability = [ordered]@{
                        testedUtc = [datetime]::UtcNow.ToString('o'); canList = $false; canDownload = $false; collections = @()
                        summary = 'Demo mode: the capability test needs a signed-in tenant. Use "Analyze sample diagnostics" or upload a file.'
                        steps = @([ordered]@{ name = 'Capability test'; method = '-'; endpoint = '-'; status = 'skipped'; message = 'Not available in demo mode.' })
                        docsUrl = 'https://learn.microsoft.com/en-us/intune/device-management/actions/collect-diagnostics'; docsNote = ''
                    }
                    Write-PodeJsonResponse -Depth 10 -Value $app.Capability; return
                }
                if (-not (Get-AdAccessToken -AppState $app)) { Write-PodeJsonResponse -StatusCode 401 -Value @{ error = 'Sign in first.'; code = 'not_signed_in' }; return }
                $deviceId = [string]$WebEvent.Data.managedDeviceId
                if (-not (Test-AdGuid $deviceId) -and $app.Model) {
                    $deviceId = @($app.Model.deployments | Where-Object { $_.status -eq 'Failed' -and (Test-AdGuid $_.managedDeviceId) } | Select-Object -First 1 | ForEach-Object { $_.managedDeviceId })[0]
                }
                $tp = { Get-AdAccessToken -AppState $app }.GetNewClosure()
                $app.Capability = Test-AdDiagnosticsCapability -TokenProvider $tp -Config $app.Config -ManagedDeviceId $deviceId
                Write-AdLog -Message "Diagnostics capability test: list=$($app.Capability.canList) download=$($app.Capability.canDownload)."
                $out = $app.Capability
                if ($app.Anonymize) { $out = Protect-AdPayload -Payload $out -SensitiveValues ([ordered]@{}) -Key $app.AnonymizeKey }
                Write-PodeJsonResponse -Depth 10 -Value $out
            }
            catch { Write-PodeJsonResponse -StatusCode 500 -Value @{ error = (Get-AdGraphErrorInfo $_).message } }
        }

        Add-PodeRoute -Method Post -Path '/api/diagnostics/list' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            try {
                if (-not (Get-AdAccessToken -AppState $app)) { Write-PodeJsonResponse -StatusCode 401 -Value @{ error = 'Sign in first.'; code = 'not_signed_in' }; return }
                $tp = { Get-AdAccessToken -AppState $app }.GetNewClosure()
                $list = Get-AdDiagnosticsList -TokenProvider $tp -ManagedDeviceId ([string]$WebEvent.Data.managedDeviceId) -Config $app.Config
                $out = @{ collections = $list }
                if ($app.Anonymize) { $out = Protect-AdPayload -Payload $out -SensitiveValues ([ordered]@{}) -Key $app.AnonymizeKey }
                Write-PodeJsonResponse -Depth 10 -Value $out
            }
            catch {
                $info = Get-AdGraphErrorInfo $_
                $msg = if ($info.status -eq 403) { 'Graph returned 403 Forbidden for this account. Download the diagnostics from the Intune admin center and upload them here.' } else { $info.message }
                Write-PodeJsonResponse -StatusCode 400 -Value @{ error = $msg; status = $info.status }
            }
        }

        Add-PodeRoute -Method Post -Path '/api/diagnostics/fetch' -ScriptBlock {
            # action = download (file to browser) | analyze (parse in temp, then delete)
            $app = Get-PodeState -Name 'App'
            $temp = $null
            try {
                if (-not (Get-AdAccessToken -AppState $app)) { Write-PodeJsonResponse -StatusCode 401 -Value @{ error = 'Sign in first.'; code = 'not_signed_in' }; return }
                $deviceId = [string]$WebEvent.Data.managedDeviceId
                $requestId = [string]$WebEvent.Data.requestId
                $action = [string]$WebEvent.Data.action
                if ($action -eq 'download' -and -not [bool]$WebEvent.Data.acknowledged) { throw 'Confirm the sensitivity warning before downloading.' }
                $tp = { Get-AdAccessToken -AppState $app }.GetNewClosure()
                $url = Get-AdDiagnosticsDownloadUrl -TokenProvider $tp -ManagedDeviceId $deviceId -RequestId $requestId -Config $app.Config
                $bytes = Get-AdDiagnosticsContent -Url $url -MaxBytes ([long]$app.Config.maxUploadMB * 1MB)
                $url = $null
                $name = "IntuneDiagnostics-$($requestId.Substring(0, [math]::Min(8, $requestId.Length))).zip"
                if ($action -eq 'download') {
                    $ticket = New-AdDownloadTicket -AppState $app -Bytes $bytes -FileName $name -ContentType 'application/zip'
                    Write-PodeJsonResponse -Value @{ url = "/api/download/$ticket" }
                    return
                }
                $temp = New-AdTempFolder
                $path = Join-Path $temp $name
                [System.IO.File]::WriteAllBytes($path, $bytes)
                $analysis = Invoke-AdLogAnalysis -ArchivePath $path -FileName $name -Rules $app.Rules -Config $app.Config -Origin 'intune'
                if (-not $analysis.managedDeviceId) { $analysis.managedDeviceId = $deviceId }
                Add-AdLogAnalysis -AppState $app -Analysis $analysis
                Write-PodeJsonResponse -Value @{ ok = $true; id = $analysis.id; status = $analysis.status; message = $analysis.message }
            }
            catch {
                $info = Get-AdGraphErrorInfo $_
                $msg = if ($info.status -eq 403) { 'Graph returned 403 Forbidden: downloading diagnostics through Graph is not permitted for this account. Download them in the Intune admin center and upload them here.' } else { $info.message }
                Write-PodeJsonResponse -StatusCode 400 -Value @{ error = $msg; status = $info.status }
            }
            finally { Remove-AdTempFolder $temp }
        }

        Add-PodeRoute -Method Post -Path '/api/logs/upload' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            $temp = $null
            try {
                $file = @($WebEvent.Files.Values) | Select-Object -First 1
                if (-not $file) { throw 'No file received.' }
                $name = [System.IO.Path]::GetFileName([string]$file.FileName)
                $ext = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
                if ($ext -notin '.zip', '.cab') { throw 'Only .zip and .cab files are supported.' }
                $max = [long]$app.Config.maxUploadMB * 1MB
                if ($file.Bytes.Length -gt $max) { Write-PodeJsonResponse -StatusCode 413 -Value @{ error = "File is larger than the $($app.Config.maxUploadMB) MB limit." }; return }
                if ($file.Bytes.Length -lt 22) { throw 'File is empty or truncated.' }
                $temp = New-AdTempFolder
                $path = Join-Path $temp ("upload$ext")
                [System.IO.File]::WriteAllBytes($path, $file.Bytes)
                $analysis = Invoke-AdLogAnalysis -ArchivePath $path -FileName $name -Rules $app.Rules -Config $app.Config -Origin 'upload'
                Add-AdLogAnalysis -AppState $app -Analysis $analysis
                Write-AdLog -Message "Uploaded diagnostics analysed (status $($analysis.status))."
                Write-PodeJsonResponse -Value @{ ok = $analysis.status -ne 'error'; id = $analysis.id; status = $analysis.status; message = $analysis.message }
            }
            catch { Write-PodeJsonResponse -StatusCode 400 -Value @{ error = Protect-AdLogText $_.Exception.Message } }
            finally { Remove-AdTempFolder $temp }
        }

        Add-PodeRoute -Method Post -Path '/api/logs/sample' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            $zip = $null
            try {
                $zip = New-AdDemoDiagnosticsArchive -SampleFolder (Join-Path $app.RootPath 'demo\sample-diagnostics')
                $analysis = Invoke-AdLogAnalysis -ArchivePath $zip -FileName 'Contoso-sample-diagnostics.zip' -Rules $app.Rules -Config $app.Config -Origin 'sample'
                Add-AdLogAnalysis -AppState $app -Analysis $analysis
                Write-PodeJsonResponse -Value @{ ok = $true; id = $analysis.id; status = $analysis.status; message = $analysis.message }
            }
            catch { Write-PodeJsonResponse -StatusCode 400 -Value @{ error = $_.Exception.Message } }
            finally { if ($zip) { Remove-AdTempFolder (Split-Path -Parent $zip) } }
        }

        Add-PodeRoute -Method Post -Path '/api/logs/clear' -ScriptBlock {
            $app = Get-PodeState -Name 'App'
            $app.Logs.Clear()
            Update-AdModel -AppState $app
            Write-PodeJsonResponse -Value @{ ok = $true }
        }

        Write-AdLog -Message "Autopilot Dashboard listening on http://127.0.0.1:$port/ (local only). Press Ctrl+C to stop."
    }
}
