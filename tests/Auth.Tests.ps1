#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src\AutopilotDashboard.psm1') -Force
    function New-Settings([hashtable]$Values) {
        $p = Join-Path $TestDrive ("s-{0}.json" -f [guid]::NewGuid().ToString('N'))
        $Values | ConvertTo-Json | Set-Content $p
        return $p
    }
    function New-FakeJwt([hashtable]$Claims) {
        $enc = { param($o) [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        '{0}.{1}.sig' -f (& $enc @{ alg = 'none' }), (& $enc $Claims)
    }
    $script:graphCliId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
}

Describe 'Sign-in configuration' {
    It 'is not configured in custom mode without tenantId and clientId' {
        (Get-AdConfig -Path (New-Settings @{ authMode = 'custom' })).isConfigured | Should -BeFalse
    }

    It 'graphCli mode needs no registration: uses the Graph Command Line Tools client and the organizations authority' {
        $c = Get-AdConfig -Path (New-Settings @{ authMode = 'graphCli' })
        $c.isConfigured | Should -BeTrue
        $c.clientId | Should -Be $graphCliId
        $c.authority | Should -Be 'organizations'
        Get-AdRedirectUri $c | Should -Be 'http://localhost:8765'
    }

    It 'graphCli mode ignores a custom clientId and uses tenantId as authority when set' {
        $c = Get-AdConfig -Path (New-Settings @{ authMode = 'graphCli'; clientId = '11111111-1111-1111-1111-111111111111'; tenantId = 'contoso.onmicrosoft.com' })
        $c.clientId | Should -Be $graphCliId
        $c.authority | Should -Be 'contoso.onmicrosoft.com'
    }

    It 'custom mode uses 127.0.0.1 and the configured IDs' {
        $c = Get-AdConfig -Path (New-Settings @{ tenantId = '22222222-2222-2222-2222-222222222222'; clientId = '11111111-1111-1111-1111-111111111111'; port = 9001 })
        $c.authMode | Should -Be 'custom'
        $c.isConfigured | Should -BeTrue
        Get-AdRedirectUri $c | Should -Be 'http://127.0.0.1:9001/auth/callback'
    }

    It 'rejects an unknown authMode and multi-tenant aliases' {
        { Get-AdConfig -Path (New-Settings @{ authMode = 'magic' }) } | Should -Throw '*authMode*'
        { Get-AdConfig -Path (New-Settings @{ authMode = 'graphCli'; tenantId = 'common' }) } | Should -Throw '*multi-tenant alias*'
    }
}

Describe 'Authorization request' {
    It 'builds a PKCE request for the Graph Command Line Tools app with the localhost redirect' {
        $c = Get-AdConfig -Path (New-Settings @{ authMode = 'graphCli' })
        $r = New-AdAuthorizationRequest -Config $c
        $u = [uri]$r.Url
        $u.Host | Should -Be 'login.microsoftonline.com'
        $u.AbsolutePath | Should -Be '/organizations/oauth2/v2.0/authorize'
        $r.Url | Should -Match "client_id=$graphCliId"
        $r.Url | Should -Match 'redirect_uri=http%3A%2F%2Flocalhost%3A8765(&|$)'
        $r.Url | Should -Match 'code_challenge_method=S256'
        $r.Url | Should -Match 'DeviceManagementManagedDevices.Read.All'
        $r.Url | Should -Not -Match 'ReadWrite'
        $r.Verifier.Length | Should -BeGreaterOrEqual 43
    }
}

Describe 'Callback handling' {
    BeforeEach {
        $c = Get-AdConfig -Path (New-Settings @{ authMode = 'graphCli'; tenantId = '33333333-3333-3333-3333-333333333333' })
        $script:state = New-AdAppState -Config $c -RootPath $root -Rules @()
        $script:req = New-AdAuthorizationRequest -Config $c
        $state.Auth.Pending = $req
    }

    It 'rejects a state mismatch without calling the token endpoint' {
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest { throw 'must not be called' }
        Invoke-AdAuthCallback -AppState $state -Query @{ code = 'abc'; state = 'wrong' }
        $state.Auth.Status | Should -Be 'signedOut'
        $state.Auth.Message | Should -Match 'state mismatch'
        $state.Auth.Pending | Should -BeNullOrEmpty -Because 'the pending request is single use'
        Should -Invoke -ModuleName AutopilotDashboard Invoke-WebRequest -Times 0 -Exactly
    }

    It 'shows an Entra error returned on the redirect' {
        Invoke-AdAuthCallback -AppState $state -Query @{ error = 'access_denied'; error_description = "AADSTS65001: consent required`r`nTrace ID: x" }
        $state.Auth.Message | Should -Match 'access_denied'
        $state.Auth.Message | Should -Not -Match 'Trace ID'
    }

    It 'exchanges the code with the same redirect URI and PKCE verifier, and keeps tokens in memory' {
        $jwt = New-FakeJwt @{ aud = $graphCliId; tid = '33333333-3333-3333-3333-333333333333'; nonce = $req.Nonce; name = 'Admin'; preferred_username = 'admin@contoso.example' }
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Content = (@{ access_token = 'at'; refresh_token = 'rt'; id_token = $jwt; expires_in = 3600; scope = 'x' } | ConvertTo-Json) }
        } -ParameterFilter { $Body.redirect_uri -eq 'http://localhost:8765' -and $Body.code_verifier -eq $req.Verifier -and $Body.client_id -eq $graphCliId -and $Uri -like '*/33333333-3333-3333-3333-333333333333/oauth2/v2.0/token' }
        Invoke-AdAuthCallback -AppState $state -Query @{ code = 'abc'; state = $req.State }
        $state.Auth.Status | Should -Be 'signedIn'
        $state.Auth.Account.domain | Should -Be 'contoso.example'
        (Get-AdAuthStatus -AppState $state | ConvertTo-Json) | Should -Not -Match '"at"|"rt"' -Because 'tokens are never sent to the browser'
    }

    It 'rejects an account from another tenant than the configured tenantId' {
        $jwt = New-FakeJwt @{ aud = $graphCliId; tid = '44444444-4444-4444-4444-444444444444'; nonce = $req.Nonce }
        Mock -ModuleName AutopilotDashboard Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = (@{ access_token = 'at'; id_token = $jwt; expires_in = 3600 } | ConvertTo-Json) } }
        Invoke-AdAuthCallback -AppState $state -Query @{ code = 'abc'; state = $req.State }
        $state.Auth.Status | Should -Be 'signedOut'
        $state.Auth.AccessToken | Should -BeNullOrEmpty
        $state.Auth.Message | Should -Match 'different tenant'
    }
}
