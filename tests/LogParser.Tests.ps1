#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src\AutopilotDashboard.psm1') -Force
    $script:rules = Import-AdRules -Path (Join-Path $root 'rules.json')
    $script:sample = Join-Path $root 'demo\sample-diagnostics'
    $script:cfg = Get-AdDefaultConfig
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    function New-TestZip([string]$Path, [hashtable]$Entries) {
        $fs = [System.IO.File]::Create($Path)
        $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($k in $Entries.Keys) {
            $e = $zip.CreateEntry($k)
            $w = [System.IO.StreamWriter]::new($e.Open())
            $w.Write($Entries[$k]); $w.Dispose()
        }
        $zip.Dispose(); $fs.Dispose()
    }
    function Get-TempRootCount { $p = Join-Path ([System.IO.Path]::GetTempPath()) 'AutopilotDashboard'; if (Test-Path $p) { @(Get-ChildItem $p).Count } else { 0 } }
}

Describe 'Registry dump parsing' {
    It 'reads UTF-16 .reg files with dword and string values' {
        $e = Read-AdRegFile -Path (Join-Path $sample 'MDMDiagReport_RegistryDump.Reg')
        $info = Get-AdAutopilotRegistryInfo -Entries $e
        $info.TenantMatched | Should -Be 1
        $info.IsAutopilotDisabled | Should -Be 0
        $info.CloudAssignedTenantDomain | Should -Be 'contoso.example'
    }

    It 'reads ESP InstallationState with the documented state names' {
        $esp = Get-AdEspTracking -Entries (Read-AdRegFile -Path (Join-Path $sample 'MDMDiagReport_RegistryDump.Reg'))
        ($esp | Where-Object installationState -eq 4).stateName | Should -Be 'Error'
        ($esp | Where-Object scope -eq 'Device preparation').stateName | Should -Be 'Completed'
    }

    It 'finds the serial number and Intune device ID (EntDMID) for matching' {
        $ids = Get-AdDeviceIdentifiersFromRegistry -Entries (Read-AdRegFile -Path (Join-Path $sample 'MDMDiagReport_RegistryDump.Reg'))
        $ids.SerialNumber | Should -Be 'CTSDEMO0007'
        $ids.ManagedDeviceId | Should -Be '5b7c0007-1111-4222-8333-000000000007'
    }

    It 'handles TenantMatched = 0 and IsAutopilotDisabled = 1 as findings' {
        $reg = "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot]`r`n`"TenantMatched`"=dword:00000000`r`n`"IsAutopilotDisabled`"=dword:00000001`r`n"
        $p = Join-Path $TestDrive 'MDMDiagReport_RegistryDump.Reg'
        [System.IO.File]::WriteAllText($p, $reg, [System.Text.UnicodeEncoding]::new($false, $true))
        $info = Get-AdAutopilotRegistryInfo -Entries (Read-AdRegFile -Path $p)
        $la = [ordered]@{ fileName = 't'; autopilotRegistry = $info; espTracking = @(); autopilotEvents = @(); textSignals = @() }
        $f = Find-AdRuleMatches -Evidence (Get-AdLogEvidence $la) -Rules $rules
        $f.ruleId | Should -Contain 'REG-TENANTMATCHED-0'
        $f.ruleId | Should -Contain 'REG-ISAUTOPILOTDISABLED-NOTREG'
    }

    It 'maps Autopilot event log entries to event-ID evidence' {
        $la = [ordered]@{ fileName = 't'; autopilotRegistry = $null; espTracking = @(); textSignals = @()
            autopilotEvents = @([ordered]@{ id = 815; time = '2026-10-01T10:00:00Z'; level = 'Error'; message = 'ZtdDeviceHasNoAssignedProfile' }) }
        (Find-AdRuleMatches -Evidence (Get-AdLogEvidence $la) -Rules $rules).ruleId | Should -Contain 'AP-EVT-815'
    }
}

Describe 'mdmdiagnosticstool registry dump format (real-world variant)' {
    BeforeAll {
        # Same shape as a real Intune Collect dump: UTF-8 without BOM, indented values, upper-case
        # DWORD:/QWORD:/MULTI_SZ:, different capitalisation, and a CSP node-cache key that must be ignored.
        $reg = @'
[HKEY_LOCAL_MACHINE\software\microsoft\provisioning\Diagnostics\AutoPilot]
    "IsAutoPilotDisabled"=DWORD:00000001
    "TenantMatched"=DWORD:00000000
    "CloudAssignedTenantDomain"="fabrikam.example"
    "SomeTimestamp"=QWORD:00000000000003e8
    "SomeList"=MULTI_SZ:a b

[HKEY_LOCAL_MACHINE\software\microsoft\provisioning\CSPs\.\Device\Vendor\MSFT\EnrollmentStatusTracking\Setup]
    "InstallationState"=DWORD:00000004

[HKEY_LOCAL_MACHINE\software\microsoft\windows\autopilot\EnrollmentStatusTracking\S-1-12-1-1-2-3-4\Setup\Apps\Tracking\Sidecar\Win32App_aaaa_1]
    "InstallationState"=DWORD:00000004

[HKEY_LOCAL_MACHINE\software\microsoft\enrollments\{11111111-2222-3333-4444-555555555555}\DMClient\MS DM Server]
    "EntDMID"="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
'@
        $script:regPath = Join-Path $TestDrive 'MdmDiagReport_RegistryDump.reg'
        [System.IO.File]::WriteAllText($regPath, $reg.Replace("`r`n", "`n").Replace("`n", "`r`n"), [System.Text.UTF8Encoding]::new($false))
        $script:entries = Read-AdRegFile -Path $regPath
    }

    It 'parses UTF-8 without BOM and indented values' {
        $info = Get-AdAutopilotRegistryInfo -Entries $entries
        $info.IsAutopilotDisabled | Should -Be 1
        $info.TenantMatched | Should -Be 0
        $info.CloudAssignedTenantDomain | Should -Be 'fabrikam.example'
    }

    It 'parses QWORD and MULTI_SZ values' {
        ($entries | Where-Object Name -eq 'SomeTimestamp').Value | Should -Be 1000
        ($entries | Where-Object Name -eq 'SomeList').Type | Should -Be 'multi_sz'
    }

    It 'reads ESP tracking only from Windows\Autopilot\EnrollmentStatusTracking, not the CSP node cache' {
        $esp = Get-AdEspTracking -Entries $entries
        @($esp).Count | Should -Be 1
        $esp[0].scope | Should -Be 'Account setup'
        $esp[0].stateName | Should -Be 'Error'
    }

    It 'finds EntDMID with lower-case key paths' {
        (Get-AdDeviceIdentifiersFromRegistry -Entries $entries).ManagedDeviceId | Should -Be 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    }
}

Describe 'Intune Collect diagnostics layout (real-world variant)' {
    It 'extracts several nested cabs under long folder names, ignores unrelated logs and de-duplicates copies' {
        $root = Join-Path $TestDrive 'collect'
        $long = 'FoldersFiles temp_MDMDiagnostics_mdmlogs-2026-11-02-12-44-57_cab_' + ('x' * 60)
        $work = Join-Path $TestDrive 'cabsrc'; New-Item -ItemType Directory $work | Out-Null
        Copy-Item (Join-Path $sample 'MDMDiagReport_RegistryDump.Reg') $work
        $ddf = Join-Path $TestDrive 'n.ddf'
        @(".Set CabinetNameTemplate=mdmlogs.cab", ".Set DiskDirectoryTemplate=$TestDrive", "`"$work\MDMDiagReport_RegistryDump.Reg`"") | Set-Content $ddf
        Push-Location $TestDrive; & makecab.exe /F $ddf | Out-Null; Pop-Location
        foreach ($n in 1..3) {
            $d = Join-Path $root "($n) $long"; New-Item -ItemType Directory $d -Force | Out-Null
            Copy-Item (Join-Path $TestDrive 'mdmlogs.cab') $d
        }
        # Same IME log twice, plus a Defender log with a generic timeout code that must be ignored.
        foreach ($n in 4, 5) {
            $d = Join-Path $root "($n) FoldersFiles ProgramData_Microsoft_IntuneManagementExtension_Logs"; New-Item -ItemType Directory $d -Force | Out-Null
            Set-Content (Join-Path $d 'AppWorkload.log') 'Install failed: Another installation is in progress, please try again later.'
        }
        $mp = Join-Path $root '(6) FoldersFiles ProgramData_Microsoft_Windows Defender_Support'; New-Item -ItemType Directory $mp -Force | Out-Null
        Set-Content (Join-Path $mp 'MPLog-20261102.log') 'Signature update failed 0x800705b4'
        $zip = Join-Path $TestDrive 'DiagLogs.zip'
        Compress-Archive -Path (Join-Path $root '*') -DestinationPath $zip

        $a = Invoke-AdLogAnalysis -ArchivePath $zip -FileName 'DiagLogs.zip' -Rules $rules -Config $cfg
        $a.status | Should -Be 'ok' -Because $a.message
        $a.autopilotRegistry.TenantMatched | Should -Be 1
        @($a.textSignals).Count | Should -Be 1 -Because 'duplicate copies are reported once and MPLog is not scanned'
        $a.textSignals[0].file | Should -Be 'AppWorkload.log'
        $a.findings.ruleId | Should -Contain 'TXT-ANOTHER-INSTALL'
        $a.findings.ruleId | Should -Not -Contain 'ERR-800705B4-GENERIC'
    }

    It 'reads the Autopilot event log from a path longer than MAX_PATH' {
        $evtx = Join-Path $TestDrive 'ap.evtx'
        & wevtutil.exe epl 'Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot' $evtx 2>$null
        $expected = if (Test-Path $evtx) { @(Get-WinEvent -Path $evtx -MaxEvents 5000 -ErrorAction SilentlyContinue).Count } else { 0 }
        if ($expected -eq 0) { Set-ItResult -Skipped -Because 'no Autopilot events on this machine to build a test log from'; return }
        $deep = Join-Path $TestDrive ('collect2\(31) FoldersFiles ' + ('y' * 120) + '\' + ('z' * 100))
        New-Item -ItemType Directory $deep -Force | Out-Null
        Copy-Item $evtx (Join-Path $deep 'microsoft-windows-moderndeployment-diagnostics-provider-autopilot.evtx')
        $zip = Join-Path $TestDrive 'longpath.zip'
        Compress-Archive -Path (Join-Path $TestDrive 'collect2\*') -DestinationPath $zip
        $a = Invoke-AdLogAnalysis -ArchivePath $zip -FileName 'longpath.zip' -Rules $rules -Config $cfg
        $a.status | Should -Not -Be 'error' -Because $a.message
        $a.filesFound | Should -Contain 'microsoft-windows-moderndeployment-diagnostics-provider-autopilot.evtx'
        @($a.autopilotEvents).Count | Should -Be $expected
    }
}

Describe 'Archive analysis' {
    It 'analyses the sample .zip end to end and cleans up its temp folder' {
        $before = Get-TempRootCount
        $zip = Join-Path $TestDrive 'sample.zip'
        Compress-Archive -Path (Join-Path $sample '*') -DestinationPath $zip
        $a = Invoke-AdLogAnalysis -ArchivePath $zip -FileName 'sample.zip' -Rules $rules -Config $cfg
        $a.status | Should -Be 'ok'
        $a.serialNumber | Should -Be 'CTSDEMO0007'
        $a.findings.ruleId | Should -Contain 'ESP-INSTALLSTATE-4'
        $a.findings.ruleId | Should -Contain 'TXT-ANOTHER-INSTALL'
        Get-TempRootCount | Should -Be $before
    }

    It 'handles a .cab nested inside a .zip (Intune Collect diagnostics layout)' -Skip:(-not $IsWindows) {
        $work = Join-Path $TestDrive 'cabwork'; New-Item -ItemType Directory $work | Out-Null
        Copy-Item (Join-Path $sample 'MDMDiagReport_RegistryDump.Reg') $work
        $ddf = Join-Path $TestDrive 'x.ddf'
        @(".Set CabinetNameTemplate=mdmlogs.cab", ".Set DiskDirectoryTemplate=$TestDrive", ".Set Compress=on", "`"$work\MDMDiagReport_RegistryDump.Reg`"") | Set-Content $ddf
        Push-Location $TestDrive; & makecab.exe /F $ddf | Out-Null; Pop-Location
        $cab = Join-Path $TestDrive 'mdmlogs.cab'
        Test-Path $cab | Should -BeTrue
        $zip = Join-Path $TestDrive 'collect.zip'
        $folder = Join-Path $TestDrive '(55) FoldersFiles temp_MDMDiagnostics'; New-Item -ItemType Directory $folder | Out-Null
        Copy-Item $cab $folder
        Compress-Archive -Path $folder -DestinationPath $zip
        $a = Invoke-AdLogAnalysis -ArchivePath $zip -FileName 'collect.zip' -Rules $rules -Config $cfg
        $a.status | Should -Be 'ok'
        $a.autopilotRegistry.TenantMatched | Should -Be 1
    }

    It 'rejects zip-slip entries (<_>)' -ForEach @('../evil.txt', '..\evil.txt', 'a/../../evil.txt', 'C:/Windows/evil.txt', '/abs/evil.txt') {
        $zip = Join-Path $TestDrive "slip-$([guid]::NewGuid().ToString('N')).zip"
        New-TestZip $zip @{ $_ = 'x' }
        $a = Invoke-AdLogAnalysis -ArchivePath $zip -FileName 'slip.zip' -Rules $rules -Config $cfg
        $a.status | Should -Be 'error'
        $a.message | Should -Match 'Unsafe path|escapes'
        Test-Path (Join-Path ([System.IO.Path]::GetTempPath()) 'evil.txt') | Should -BeFalse
    }

    It 'enforces the extracted-size limit (zip bomb protection)' {
        $zip = Join-Path $TestDrive 'big.zip'
        New-TestZip $zip @{ 'big.log' = ('A' * 3MB) }
        $small = Get-AdDefaultConfig; $small.maxExtractedMB = 1
        $a = Invoke-AdLogAnalysis -ArchivePath $zip -FileName 'big.zip' -Rules $rules -Config $small
        $a.status | Should -Be 'error'
        $a.message | Should -Match 'exceeds'
    }

    It 'enforces the entry-count limit' {
        $zip = Join-Path $TestDrive 'many.zip'
        $h = @{}; 1..30 | ForEach-Object { $h["f$_.txt"] = 'x' }
        New-TestZip $zip $h
        $c = Get-AdDefaultConfig; $c.maxArchiveEntries = 10
        (Invoke-AdLogAnalysis -ArchivePath $zip -FileName 'many.zip' -Rules $rules -Config $c).message | Should -Match 'more than 10 entries'
    }

    It 'rejects files that are not real zip/cab archives and wrong extensions' {
        $fake = Join-Path $TestDrive 'fake.zip'; Set-Content $fake 'MZ this is an exe'
        (Invoke-AdLogAnalysis -ArchivePath $fake -FileName 'fake.zip' -Rules $rules -Config $cfg).status | Should -Be 'error'
        (Invoke-AdLogAnalysis -ArchivePath $fake -FileName 'tool.exe' -Rules $rules -Config $cfg).message | Should -Match 'Only .zip and .cab'
    }

    It 'warns when an archive contains no Autopilot data' {
        $zip = Join-Path $TestDrive 'empty.zip'
        New-TestZip $zip @{ 'readme.md' = 'nothing here' }
        (Invoke-AdLogAnalysis -ArchivePath $zip -FileName 'empty.zip' -Rules $rules -Config $cfg).status | Should -Be 'warning'
    }

    It 'sanitises the file name it reports' {
        $zip = Join-Path $TestDrive 's.zip'; New-TestZip $zip @{ 'a.txt' = 'x' }
        $a = Invoke-AdLogAnalysis -ArchivePath $zip -FileName '..\..\<script>x.zip' -Rules $rules -Config $cfg
        $a.fileName | Should -Not -Match '[<>\\]'
    }
}

Describe 'Log matching' {
    It 'attaches a log to the deployment with the same serial number' {
        $ds = New-AdDemoDataset -Count 20
        $zip = Join-Path $TestDrive 'm.zip'
        Compress-Archive -Path (Join-Path $sample '*') -DestinationPath $zip
        $a = Invoke-AdLogAnalysis -ArchivePath $zip -FileName 'm.zip' -Rules $rules -Config $cfg
        $m = ConvertTo-AdDeploymentModel -Dataset $ds -Rules $rules -LogAnalyses @($a)
        $d = $m | Where-Object serial -eq 'CTSDEMO0007'
        $d.logAnalysisIds | Should -Contain $a.id
        $a.matchedBy | Should -Be 'serial number'
        $d.findings.ruleId | Should -Contain 'ESP-INSTALLSTATE-4'
        $d.failedItems.name | Should -Contain 'Win32 app 3a9e7c1d-5f2b-4d8e-a6c4-9b0f1e2d3c4a' -Because 'ESP errors from diagnostics feed the failing apps list'
    }
}
