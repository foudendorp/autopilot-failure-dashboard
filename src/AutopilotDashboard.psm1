#Requires -Version 7.4
# Autopilot Dashboard core module. All functions live in Private\*.ps1 and are exported
# so the Pode route runspaces and the Pester tests can use them.

Set-StrictMode -Version 1.0

foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' | Sort-Object Name) {
    . $file.FullName
}

Export-ModuleMember -Function *
