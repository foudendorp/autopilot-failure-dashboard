#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Static checks for the standalone scripts in scripts/: they must parse and stay read-only.
BeforeDiscovery {
    $script:files = Get-ChildItem (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') -Filter '*.ps1'
}

Describe '<_.Name>' -ForEach $files {
    BeforeAll {
        $tokens = $null; $errors = $null
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
        $script:parseErrors = $errors
        $script:commands = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
    }

    It 'parses without errors' {
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'calls Microsoft Graph with GET only' {
        $graphCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-MgGraphRequest' })
        $graphCalls.Count | Should -BeGreaterThan 0
        foreach ($c in $graphCalls) {
            $c.Extent.Text | Should -Match '-Method\s+GET\b' -Because $c.Extent.Text
        }
    }

    It 'does not use other HTTP clients or write cmdlets' {
        $names = @($commands | ForEach-Object { $_.GetCommandName() })
        $names | Should -Not -Contain 'Invoke-RestMethod'
        $names | Should -Not -Contain 'Invoke-WebRequest'
        @($names | Where-Object { $_ -match '^(New|Set|Update|Remove|Invoke)-Mg(?!GraphRequest)' }) | Should -BeNullOrEmpty
    }
}
