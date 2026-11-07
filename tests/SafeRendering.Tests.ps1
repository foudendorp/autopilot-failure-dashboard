#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Static checks on the front end plus an integration test of the running server's security controls.
BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:web = Join-Path $root 'web'
    $script:js = Get-ChildItem (Join-Path $web 'assets') -Filter '*.js'
}

Describe 'Front-end safe rendering (static analysis)' {
    It '<_.Name> never uses HTML-string sinks' -ForEach (Get-ChildItem (Join-Path (Split-Path -Parent $PSScriptRoot) 'web\assets') -Filter '*.js') {
        $code = Get-Content $_.FullName -Raw
        $code | Should -Not -Match '\.innerHTML|\.outerHTML|insertAdjacentHTML|document\.write|\beval\s*\(|new\s+Function\s*\(|setTimeout\s*\(\s*[''"`]'
    }

    It 'index.html has no inline scripts, inline styles, event handler attributes or external resources' {
        $html = Get-Content (Join-Path $web 'index.html') -Raw
        $html | Should -Not -Match '<script(?![^>]*\bsrc=)[^>]*>'
        $html | Should -Not -Match '<style'
        $html | Should -Not -Match '\sstyle='
        $html | Should -Not -Match '\son[a-z]+='
        $html | Should -Not -Match '(src|href)="(https?:)?//'
    }

    It 'loads no CDN resources anywhere in the web folder' {
        foreach ($f in Get-ChildItem $web -Recurse -File -Include '*.js', '*.css', '*.html') {
            (Get-Content $f.FullName -Raw) | Should -Not -Match '(cdn\.|unpkg\.com|jsdelivr|googleapis\.com|@import\s+url\(\s*[''"]?https?:)'
        }
    }

    It 'dom.js refuses event-handler and style attributes and unsafe URLs' {
        $dom = Get-Content (Join-Path $web 'assets\dom.js') -Raw
        $dom | Should -Match 'BLOCKED_ATTR = /\^on/i'
        $dom | Should -Match "learn\.microsoft\.com"
        $dom | Should -Match 'Inline style attributes are not allowed'
    }
}

Describe 'Server security controls (integration, demo mode)' {
    BeforeAll {
        $script:port = Get-Random -Minimum 20000 -Maximum 40000
        $script:base = "http://127.0.0.1:$port"
        $log = Join-Path $TestDrive 'server.log'
        # Own settings file so the test doesn't depend on config\settings.json; graphCli mode exercises the localhost callback.
        $settings = Join-Path $TestDrive 'settings.json'
        @{ authMode = 'graphCli'; port = $port; openBrowser = $false } | ConvertTo-Json | Set-Content $settings
        $script:proc = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', ('"{0}"' -f (Join-Path $root 'Start-AutopilotDashboard.ps1')), '-Demo', '-NoBrowser', '-ConfigPath', ('"{0}"' -f $settings)) -PassThru -WindowStyle Hidden -RedirectStandardOutput $log
        $deadline = (Get-Date).AddSeconds(60)
        do {
            Start-Sleep -Milliseconds 500
            try { $script:boot = Invoke-RestMethod "$base/api/bootstrap" -TimeoutSec 2; break } catch { }
        } while ((Get-Date) -lt $deadline)
        if (-not $script:boot) { throw "Server did not start: $(Get-Content $log -Raw)" }
        $script:okHeaders = @{ Origin = $base; 'X-CSRF-Token' = $boot.csrfToken }
    }
    AfterAll { if ($script:proc -and -not $script:proc.HasExited) { Stop-Process -Id $script:proc.Id -Force } }

    It 'listens on 127.0.0.1 only' {
        $listeners = Get-NetTCPConnection -LocalPort $port -State Listen
        $listeners.LocalAddress | Sort-Object -Unique | Should -Be '127.0.0.1'
    }

    It 'sends a strict Content-Security-Policy and hardening headers' {
        $r = Invoke-WebRequest "$base/" -SkipHttpErrorCheck
        $r.StatusCode | Should -Be 200
        $csp = [string]$r.Headers['Content-Security-Policy']
        $csp | Should -Match "default-src 'none'"
        $csp | Should -Match "script-src 'self'"
        $csp | Should -Not -Match 'unsafe-inline|unsafe-eval'
        [string]$r.Headers['X-Content-Type-Options'] | Should -Be 'nosniff'
        [string]$r.Headers['X-Frame-Options'] | Should -Be 'DENY'
        $r.Headers['Access-Control-Allow-Origin'] | Should -BeNullOrEmpty
    }

    It 'rejects a foreign Host header (DNS rebinding)' {
        (Invoke-WebRequest "$base/api/data" -Headers @{ Host = 'attacker.example' } -SkipHttpErrorCheck).StatusCode | Should -Be 403
    }

    It 'graphCli: accepts the sign-in callback on localhost and redirects to 127.0.0.1' {
        $r = Invoke-WebRequest "$base/?code=abc&state=xyz" -Headers @{ Host = "localhost:$port" } -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
        $r.StatusCode | Should -BeIn 301, 302
        [string]$r.Headers['Location'] | Should -Be "http://127.0.0.1:$port/"
        # No sign-in was pending, so the attempt is rejected (state check) and reported in the UI.
        (Invoke-RestMethod "$base/api/auth/status").status | Should -Be 'signedOut'
    }

    It 'graphCli: rejects every other request on the localhost host name (<_>)' -ForEach @('/', '/api/data', '/api/bootstrap', '/assets/app.js', '/?code=abc') {
        (Invoke-WebRequest "http://127.0.0.1:$port$_" -Headers @{ Host = "localhost:$port" } -MaximumRedirection 0 -SkipHttpErrorCheck).StatusCode | Should -Be 403
    }

    It 'reports the sign-in app and redirect URI to the UI' {
        $boot.signInApp | Should -Match 'Graph Command Line Tools'
        $boot.redirectUri | Should -Be "http://localhost:$port"
        $boot.auth.configured | Should -BeTrue
    }

    It 'serves pipeline diagnostics without personal data, and the lookup requires CSRF' {
        $p = Invoke-WebRequest "$base/api/pipeline"
        $p.StatusCode | Should -Be 200
        $p.Content | Should -Not -Match '@contoso\.example|eyJ'
        ($p.Content | ConvertFrom-Json).graph.rawRows | Should -BeGreaterThan 0
        (Invoke-WebRequest "$base/api/pipeline/lookup" -Method Post -Headers @{ Origin = $base } -ContentType 'application/json' -Body '{"query":"CTSDEMO0007"}' -SkipHttpErrorCheck).StatusCode | Should -Be 403
        $r = Invoke-RestMethod "$base/api/pipeline/lookup" -Method Post -Headers $okHeaders -ContentType 'application/json' -Body '{"query":"CTSDEMO0007"}'
        $r.matches[0].verdict | Should -Be 'shown'
    }

    It 'rejects POST without CSRF token' {
        (Invoke-WebRequest "$base/api/settings/anonymize" -Method Post -Headers @{ Origin = $base } -ContentType 'application/json' -Body '{"enabled":true}' -SkipHttpErrorCheck).StatusCode | Should -Be 403
    }

    It 'rejects POST from a foreign Origin even with the token' {
        $h = @{ Origin = 'https://attacker.example'; 'X-CSRF-Token' = $boot.csrfToken }
        (Invoke-WebRequest "$base/api/settings/anonymize" -Method Post -Headers $h -ContentType 'application/json' -Body '{"enabled":true}' -SkipHttpErrorCheck).StatusCode | Should -Be 403
    }

    It 'rejects POST without an Origin header' {
        (Invoke-WebRequest "$base/api/settings/anonymize" -Method Post -Headers @{ 'X-CSRF-Token' = $boot.csrfToken } -ContentType 'application/json' -Body '{"enabled":true}' -SkipHttpErrorCheck).StatusCode | Should -Be 403
    }

    It 'accepts a same-origin POST with the CSRF token and anonymizes the API output' {
        (Invoke-WebRequest "$base/api/settings/anonymize" -Method Post -Headers $okHeaders -ContentType 'application/json' -Body '{"enabled":true}' -SkipHttpErrorCheck).StatusCode | Should -Be 200
        $data = (Invoke-WebRequest "$base/api/data").Content
        $data | Should -Not -Match '@contoso\.example'
        $null = Invoke-WebRequest "$base/api/settings/anonymize" -Method Post -Headers $okHeaders -ContentType 'application/json' -Body '{"enabled":false}'
    }

    It 'requires the sensitivity acknowledgement before export, and download links are single-use' {
        $body = @{ format = 'csv'; ids = @(); acknowledged = $false } | ConvertTo-Json
        (Invoke-WebRequest "$base/api/export" -Method Post -Headers $okHeaders -ContentType 'application/json' -Body $body -SkipHttpErrorCheck).StatusCode | Should -Be 400
        $data = Invoke-RestMethod "$base/api/data"
        $body = @{ format = 'csv'; ids = @($data.deployments | Select-Object -First 3 | ForEach-Object id); acknowledged = $true } | ConvertTo-Json
        $r = Invoke-RestMethod "$base/api/export" -Method Post -Headers $okHeaders -ContentType 'application/json' -Body $body
        $first = Invoke-WebRequest "$base$($r.url)" -SkipHttpErrorCheck
        $first.StatusCode | Should -Be 200
        [string]$first.Headers['Content-Disposition'] | Should -Match 'attachment'
        (Invoke-WebRequest "$base$($r.url)" -SkipHttpErrorCheck).StatusCode | Should -Be 404
    }

    It 'refuses to start a refresh when not signed in' {
        $body = @{ from = '2026-10-01'; to = '2026-10-31' } | ConvertTo-Json
        (Invoke-WebRequest "$base/api/refresh" -Method Post -Headers $okHeaders -ContentType 'application/json' -Body $body -SkipHttpErrorCheck).StatusCode | Should -Be 401
    }

    It 'does not serve files outside the asset whitelist' {
        foreach ($p in '/rules.json', '/config/settings.json', '/src/Server.ps1', '/web/index.html', '/assets/../rules.json', '/public/x') {
            (Invoke-WebRequest "$base$p" -SkipHttpErrorCheck).StatusCode | Should -BeIn 403, 404 -Because "$p must not be served"
        }
    }

    It 'rejects unsupported upload types' {
        $tmp = Join-Path $TestDrive 'x.exe'; Set-Content $tmp 'MZ'
        $r = Invoke-WebRequest "$base/api/logs/upload" -Method Post -Headers $okHeaders -Form @{ file = Get-Item $tmp } -SkipHttpErrorCheck
        $r.StatusCode | Should -Be 400
    }

    It 'analyses an uploaded diagnostics zip' {
        $zip = Join-Path $TestDrive 'up.zip'
        Compress-Archive -Path (Join-Path $root 'demo\sample-diagnostics\*') -DestinationPath $zip
        $r = Invoke-RestMethod "$base/api/logs/upload" -Method Post -Headers $okHeaders -Form @{ file = Get-Item $zip }
        $r.status | Should -Be 'ok'
        $data = Invoke-RestMethod "$base/api/data"
        @($data.logs).Count | Should -BeGreaterThan 0
        ($data.deployments | Where-Object { $_.logAnalysisIds -contains $r.id }).serial | Should -Be 'CTSDEMO0007'
    }
}
