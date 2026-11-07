# Parsing of mdmdiagnosticstool (.cab) and Intune "Collect diagnostics" (.zip) archives.
# Archives are untrusted: extraction guards against zip-slip, zip bombs (size and entry limits),
# reparse points and absolute paths. Everything is extracted under a per-upload temp folder
# that is deleted in a finally block.

$script:AdRelevantLogPattern = '(?i)IntuneManagementExtension|AppWorkload|AgentExecutor|AppActionProcessor|Autopilot|Enrollment'

$script:AdEspStateNames = @{
    'Setup'             = @{ 1 = 'NotInstalled'; 2 = 'InProgress'; 3 = 'Completed'; 4 = 'Error' }
    'DevicePreparation' = @{ 1 = 'NotInstalled'; 2 = 'NotRequired'; 3 = 'Completed'; 4 = 'Error' }
}

function New-AdTempFolder {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) 'AutopilotDashboard'
    if (-not (Test-Path -LiteralPath $root)) { $null = New-Item -ItemType Directory -Path $root }
    $dir = Join-Path $root ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $dir
    return $dir
}

function Remove-AdTempFolder {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
        catch { Write-AdLog -Level WARN -Message "Could not remove temporary folder: $($_.Exception.Message)" }
    }
}

function Test-AdPathInside {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Candidate)
    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $c = [System.IO.Path]::GetFullPath($Candidate)
    return $c.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)
}

function Get-AdSafeEntryPath {
    <# Validates an archive entry name and returns the absolute destination path, or throws. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$EntryName)
    $name = $EntryName.Replace('/', '\')
    if ($name -match '^[A-Za-z]:' -or $name.StartsWith('\') -or $name -match '(^|\\)\.\.(\\|$)' -or $name.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0 -or $name -match '[:*?"<>|]') {
        throw "Unsafe path in archive rejected: '$EntryName'"
    }
    $dest = [System.IO.Path]::GetFullPath((Join-Path $Root $name))
    if (-not (Test-AdPathInside -Root $Root -Candidate $dest)) { throw "Archive entry escapes the extraction folder: '$EntryName'" }
    return $dest
}

function Expand-AdZipSafely {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][hashtable]$Budget)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            $Budget.Entries++
            if ($Budget.Entries -gt $Budget.MaxEntries) { throw "Archive has more than $($Budget.MaxEntries) entries; rejected." }
            $dest = Get-AdSafeEntryPath -Root $Destination -EntryName $entry.FullName
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { $null = New-Item -ItemType Directory -Path $dest -Force; continue }
            $Budget.Bytes += $entry.Length
            if ($Budget.Bytes -gt $Budget.MaxBytes) { throw "Extracted size exceeds $([int]($Budget.MaxBytes / 1MB)) MB; rejected." }
            $dir = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
            # Copy with a hard cap so a lying header (zip bomb) can't exceed the budget.
            $in = $entry.Open()
            $out = [System.IO.File]::Create($dest)
            try {
                $buffer = [byte[]]::new(81920); $written = 0L
                while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $written += $n
                    if ($written -gt $entry.Length + 1024) { throw 'Zip entry larger than declared; rejected.' }
                    $out.Write($buffer, 0, $n)
                }
            }
            finally { $out.Dispose(); $in.Dispose() }
        }
    }
    finally { $zip.Dispose() }
}

function Expand-AdCabSafely {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][hashtable]$Budget)
    # Windows' built-in bsdtar (libarchive) reads CAB files and keeps entry names intact.
    # (expand.exe renames the output of single-file cabs, so it isn't used.)
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) { throw 'tar.exe not found (Windows 10 1803 or later is required to read .cab files).' }
    # 1. List entries first and validate every name.
    $names = @(& $tar -tf $Path 2>$null | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { throw 'The .cab file could not be read.' }
    foreach ($n in $names) {
        $Budget.Entries++
        if ($Budget.Entries -gt $Budget.MaxEntries) { throw "Archive has more than $($Budget.MaxEntries) entries; rejected." }
        $null = Get-AdSafeEntryPath -Root $Destination -EntryName $n
    }
    # 2. Extract (libarchive also refuses absolute and '..' paths by default), then re-verify what landed on disk.
    $null = & $tar -xf $Path -C $Destination 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'The .cab file could not be extracted.' }
    foreach ($item in Get-ChildItem -LiteralPath $Destination -Recurse -Force) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $item.FullName -Force; throw 'Reparse point found in archive; rejected.' }
        if (-not (Test-AdPathInside -Root $Destination -Candidate $item.FullName)) { throw 'Extracted file outside the extraction folder; rejected.' }
        if (-not $item.PSIsContainer) {
            $Budget.Bytes += $item.Length
            if ($Budget.Bytes -gt $Budget.MaxBytes) { throw "Extracted size exceeds $([int]($Budget.MaxBytes / 1MB)) MB; rejected." }
        }
    }
}

function Expand-AdDiagnosticArchive {
    <# Extracts a .zip or .cab (and .cab/.zip files nested inside, max depth 3). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [long]$MaxBytes = 2GB,
        [int]$MaxEntries = 10000
    )
    $budget = @{ Bytes = 0L; Entries = 0; MaxBytes = $MaxBytes; MaxEntries = $MaxEntries }
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ Path = $Path; Destination = $Destination; Depth = 0 })
    while ($queue.Count) {
        $item = $queue.Dequeue()
        $p = [string]$item.Path; $d = [string]$item.Destination; $depth = [int]$item.Depth
        $ext = [System.IO.Path]::GetExtension($p).ToLowerInvariant()
        if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
        $magic = [byte[]]::new(4)
        $fs = [System.IO.File]::OpenRead($p); try { $null = $fs.Read($magic, 0, 4) } finally { $fs.Dispose() }
        $isZip = $magic[0] -eq 0x50 -and $magic[1] -eq 0x4B
        $isCab = $magic[0] -eq 0x4D -and $magic[1] -eq 0x53 -and $magic[2] -eq 0x43 -and $magic[3] -eq 0x46
        if ($ext -eq '.zip' -and $isZip) { Expand-AdZipSafely -Path $p -Destination $d -Budget $budget }
        elseif ($ext -eq '.cab' -and $isCab) { Expand-AdCabSafely -Path $p -Destination $d -Budget $budget }
        else { throw "File '$([System.IO.Path]::GetFileName($p))' is not a valid .zip or .cab archive." }

        if ($depth -lt 3) {
            foreach ($nested in Get-ChildItem -LiteralPath $d -Recurse -File -Include '*.cab', '*.zip') {
                $sub = Join-Path $nested.DirectoryName ($nested.BaseName + '_extracted')
                $queue.Enqueue([pscustomobject]@{ Path = $nested.FullName; Destination = $sub; Depth = $depth + 1 })
            }
        }
    }
    return $budget
}

function Read-AdRegFile {
    <# Parses a .reg export (MDMDiagReport_RegistryDump.Reg). Returns Key/Name/Type/Value records. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $entries = [System.Collections.Generic.List[object]]::new()
    # regedit exports are UTF-16 LE with BOM, but mdmdiagnosticstool can write UTF-8/ASCII without a BOM.
    $head = [byte[]]::new(4)
    $fs = [System.IO.File]::OpenRead($Path); try { $n = $fs.Read($head, 0, 4) } finally { $fs.Dispose() }
    $encoding = if ($n -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE) { [System.Text.Encoding]::Unicode }
    elseif ($n -ge 2 -and $head[0] -eq 0xFE -and $head[1] -eq 0xFF) { [System.Text.Encoding]::BigEndianUnicode }
    elseif ($n -ge 2 -and $head[1] -eq 0x00) { [System.Text.Encoding]::Unicode }   # UTF-16 LE without BOM
    else { [System.Text.UTF8Encoding]::new($false) }
    $reader = [System.IO.StreamReader]::new($Path, $encoding, $true)
    try {
        $key = $null; $pending = $null
        while ($null -ne ($line = $reader.ReadLine())) {
            # mdmdiagnosticstool indents value lines; regedit doesn't.
            $line = $line.Trim()
            if ($null -ne $pending) { $line = $pending + $line; $pending = $null }
            if ($line.EndsWith('\') -and $line -match '(?i)=hex') { $pending = $line.Substring(0, $line.Length - 1); continue }
            if ($line -match '^\[(.+)\]\s*$') { $key = $Matches[1]; continue }
            if (-not $key) { continue }
            if ($line -match '^(?:"((?:[^"\\]|\\.)*)"|(@))=(.*)$') {
                $name = if ($Matches[2]) { '(Default)' } else { $Matches[1] -replace '\\\\', '\' -replace '\\"', '"' }
                $raw = $Matches[3]
                $type = 'string'; $value = $null
                if ($raw -match '^"((?:[^"\\]|\\.)*)"\s*$') { $value = $Matches[1] -replace '\\\\', '\' -replace '\\"', '"' }
                elseif ($raw -match '^(?i)dword:([0-9a-f]{1,8})') { $type = 'dword'; $value = [Convert]::ToUInt32($Matches[1], 16) }
                elseif ($raw -match '^(?i)qword:([0-9a-f]{1,16})\s*$') { $type = 'qword'; $value = [Convert]::ToUInt64($Matches[1], 16) }
                elseif ($raw -match '^(?i)multi_sz:(.*)$') { $type = 'multi_sz'; $value = $Matches[1] }
                elseif ($raw -match '^(?i)hex\(b\):(.*)$') {
                    $type = 'qword'
                    $bytes = @($Matches[1] -split ',' | Where-Object { $_ -match '^[0-9a-fA-F]{2}$' } | ForEach-Object { [Convert]::ToByte($_, 16) })
                    $value = if ($bytes.Count -eq 8) { [BitConverter]::ToUInt64([byte[]]$bytes, 0) } else { $null }
                }
                elseif ($raw -match '^(?i)hex(\([0-9a-f]+\))?:(.*)$') {
                    $type = 'binary'
                    $value = ($Matches[2] -replace '\s', '')
                    if ($value.Length -gt 512) { $value = $value.Substring(0, 512) + '...' }
                }
                else { $value = $raw }
                $entries.Add([pscustomobject]@{ Key = $key; Name = $name; Type = $type; Value = $value })
            }
        }
    }
    finally { $reader.Dispose() }
    return , $entries.ToArray()
}

function Get-AdAutopilotRegistryInfo {
    param([object[]]$Entries)
    $info = [ordered]@{
        TenantMatched = $null; IsAutopilotDisabled = $null; CloudAssignedTenantDomain = $null
        CloudAssignedTenantId = $null; AadTenantId = $null; DeploymentProfileName = $null; ZtdRegistrationId = $null
    }
    $ap = @($Entries | Where-Object { $_.Key -match '(?i)\\SOFTWARE\\Microsoft\\Provisioning\\Diagnostics\\Autopilot$' })
    foreach ($e in $ap) {
        if ($info.Contains($e.Name)) { $info[$e.Name] = $e.Value }
    }
    return $info
}

function Get-AdDeviceIdentifiersFromRegistry {
    param([object[]]$Entries)
    $serial = $null; $entDmid = $null
    foreach ($e in $Entries) {
        if (-not $serial -and $e.Name -match '^(?i)(SystemSerialNumber|SerialNumber|DeviceSerialNumber|SmbiosSerialNumber)$' -and $e.Type -eq 'string' -and $e.Value -and $e.Value -notmatch '(?i)to be filled|default string|none|^0+$') { $serial = [string]$e.Value }
        if (-not $entDmid -and $e.Name -eq 'EntDMID' -and $e.Key -match '(?i)\\DMClient\\MS DM Server$' -and (Test-AdGuid ([string]$e.Value))) { $entDmid = [string]$e.Value }
    }
    [pscustomobject]@{ SerialNumber = $serial; ManagedDeviceId = $entDmid }
}

function Get-AdEspTracking {
    <# Reads ESP tracking state from HKLM\SOFTWARE\Microsoft\Windows\Autopilot\EnrollmentStatusTracking. #>
    param([object[]]$Entries)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $Entries) {
        if ($e.Name -ne 'InstallationState') { continue }
        # Only the ESP tracking key, not the CSP node cache (...\provisioning\CSPs\...\EnrollmentStatusTracking).
        if ($e.Key -notmatch '(?i)\\SOFTWARE\\Microsoft\\Windows\\Autopilot\\EnrollmentStatusTracking\\(.+)$') { continue }
        $sub = $Matches[1]
        $state = [int]$e.Value
        $scope = 'Device setup'; $names = $script:AdEspStateNames.Setup
        if ($sub -match '(?i)^Device\\DevicePreparation') { $scope = 'Device preparation'; $names = $script:AdEspStateNames.DevicePreparation }
        elseif ($sub -match '(?i)^S-1-') { $scope = 'Account setup' }
        $item = ($sub -split '\\')[-1]
        $result.Add([ordered]@{
                scope = $scope; item = $item; path = "EnrollmentStatusTracking\$sub"
                installationState = $state; stateName = if ($names.ContainsKey($state)) { $names[$state] } else { 'Unknown' }
            })
    }
    return , $result.ToArray()
}

function Read-AdAutopilotEventLog {
    <# Reads an exported Autopilot .evtx (ModernDeployment-Diagnostics-Provider/Autopilot). #>
    param([Parameter(Mandatory)][string]$Path, [int]$MaxEvents = 5000)
    $events = @()
    try { $events = @(Get-WinEvent -Path $Path -MaxEvents $MaxEvents -ErrorAction Stop) }
    catch {
        if ($_.Exception.Message -match 'No events were found') { return , @() }
        Write-AdLog -Level WARN -Message "Could not read event log $([System.IO.Path]::GetFileName($Path)): $($_.Exception.Message)"
        return , @()
    }
    return , @($events | ForEach-Object {
            $msg = $_.Message
            if (-not $msg) { $msg = ($_.Properties | ForEach-Object { [string]$_.Value }) -join ' | ' }
            if ($msg.Length -gt 2000) { $msg = $msg.Substring(0, 2000) + '...' }
            [ordered]@{ id = [int]$_.Id; time = $_.TimeCreated.ToUniversalTime().ToString('o'); level = [string]$_.LevelDisplayName; message = $msg }
        })
}

function Find-AdTextSignals {
    <# Scans text logs for rule text patterns and known error codes. Returns at most 200 hits. #>
    param([Parameter(Mandatory)][string]$Root, [string[]]$Patterns, [string[]]$ErrorCodes, [long]$MaxFileBytes = 64MB)
    $hits = [System.Collections.Generic.List[object]]::new()
    $codeRegex = if ($ErrorCodes) { '(?i)(' + (($ErrorCodes | ForEach-Object { [regex]::Escape(($_ -replace '^0x', '')) }) -join '|') + ')' } else { $null }
    $textRegex = if ($Patterns) { '(?i)(' + ($Patterns -join '|') + ')' } else { $null }
    # Only Intune / Autopilot logs: generic Windows logs (Defender MPLog, CBS, Windows Update...) contain
    # the same generic HRESULTs (e.g. 0x800705B4 timeouts) and would produce misleading findings.
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.log', '*.txt' -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -le $MaxFileBytes -and $_.Name -match $script:AdRelevantLogPattern }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $files) {
        $n = 0
        foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
            $n++
            if (($textRegex -and $line -match $textRegex) -or ($codeRegex -and $line -match $codeRegex)) {
                $t = $line.Trim()
                # CMTrace format: <![LOG[message]LOG]!><time=...> -> keep the message only
                if ($t -match '^<!\[LOG\[(.*?)\]LOG\]!>') { $t = $Matches[1] }
                if ($t.Length -gt 400) { $t = $t.Substring(0, 400) + '...' }
                # Intune Collect archives contain the same log in several folders: report each line once.
                if (-not $seen.Add("$($f.Name)|$n|$t")) { continue }
                $hits.Add([ordered]@{ file = $f.Name; line = $n; text = $t })
                if ($hits.Count -ge 200) { return , $hits.ToArray() }
            }
        }
    }
    return , $hits.ToArray()
}

function Invoke-AdLogAnalysis {
    <#
      Full pipeline for one uploaded/downloaded archive: validate -> extract to temp -> parse -> clean up.
      Only the parsed summary is kept (in memory); no extracted files survive this function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][object[]]$Rules,
        [Parameter(Mandatory)]$Config,
        [string]$Origin = 'upload'
    )
    $safeName = [System.IO.Path]::GetFileName($FileName) -replace '[^\w\.\-\(\) ]', '_'
    $analysis = [ordered]@{
        id = [guid]::NewGuid().ToString('N'); fileName = $safeName; origin = $Origin; analyzedUtc = [datetime]::UtcNow.ToString('o')
        status = 'ok'; message = ''; serialNumber = $null; managedDeviceId = $null
        autopilotRegistry = $null; espTracking = @(); autopilotEvents = @(); textSignals = @()
        filesFound = @(); newestEventTime = $null; matchedDeploymentIds = @(); matchedBy = $null; findings = @(); communityOutput = $null
    }
    $temp = New-AdTempFolder
    try {
        $ext = [System.IO.Path]::GetExtension($safeName).ToLowerInvariant()
        if ($ext -notin '.zip', '.cab') { throw 'Only .zip and .cab files are supported.' }
        $local = Join-Path $temp ("input$ext")
        Copy-Item -LiteralPath $ArchivePath -Destination $local
        $null = Expand-AdDiagnosticArchive -Path $local -Destination (Join-Path $temp 'x') -MaxBytes ([long]$Config.maxExtractedMB * 1MB) -MaxEntries ([int]$Config.maxArchiveEntries)
        $root = Join-Path $temp 'x'

        $regFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*RegistryDump*.reg' -ErrorAction SilentlyContinue)
        # The documented Autopilot event IDs (807, 815, 171, ...) belong to the ModernDeployment-Diagnostics-Provider/Autopilot
        # channel; other channels reuse the same numbers with other meanings, so only that log is read.
        # Intune Collect archives can contain the same log twice: keep one copy per name and size.
        $evtxFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.evtx' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)ModernDeployment-Diagnostics-Provider.{0,3}Autopilot' } |
                Sort-Object { "$($_.Name.ToLowerInvariant())|$($_.Length)" } -Unique)
        $analysis.filesFound = @(@($regFiles) + @($evtxFiles) | ForEach-Object { $_.Name } | Select-Object -Unique)

        $entries = @()
        foreach ($rf in $regFiles) { $entries += Read-AdRegFile -Path $rf.FullName }
        if ($entries) {
            $analysis.autopilotRegistry = Get-AdAutopilotRegistryInfo -Entries $entries
            $analysis.espTracking = Get-AdEspTracking -Entries $entries
            $ids = Get-AdDeviceIdentifiersFromRegistry -Entries $entries
            $analysis.serialNumber = $ids.SerialNumber
            $analysis.managedDeviceId = $ids.ManagedDeviceId
        }
        # Serial number fallback: MDMDiagReport.xml / msinfo32 style text
        if (-not $analysis.serialNumber) {
            foreach ($xf in Get-ChildItem -LiteralPath $root -Recurse -File -Include 'MDMDiagReport.xml', '*DeviceHash*.csv' -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 20MB }) {
                $content = [System.IO.File]::ReadAllText($xf.FullName)
                if ($content -match '(?i)<(?:SerialNumber|SystemSerialNumber)>\s*([^<\s]{4,64})\s*<') { $analysis.serialNumber = $Matches[1]; break }
                if ($xf.Extension -eq '.csv' -and $content -match '(?im)^Device Serial Number.*\r?\n"?([^",\r\n]{4,64})') { $analysis.serialNumber = $Matches[1]; break }
            }
        }

        $events = @()
        # Get-WinEvent can't open paths longer than MAX_PATH, and Intune Collect folder names are long:
        # copy each log to a short path inside the same temp folder first.
        $shortDir = Join-Path $temp 'e'
        $null = New-Item -ItemType Directory -Path $shortDir -Force
        $i = 0
        foreach ($ef in $evtxFiles) {
            $i++
            $short = Join-Path $shortDir "$i.evtx"
            [System.IO.File]::Copy($ef.FullName, $short, $true)
            $events += Read-AdAutopilotEventLog -Path $short
        }
        $analysis.autopilotEvents = @($events | Sort-Object { $_.time })
        if ($events) { $analysis.newestEventTime = ($events | Sort-Object { $_.time } -Descending | Select-Object -First 1).time }

        $patterns = @($Rules | Where-Object { $_.signal.type -eq 'text' } | ForEach-Object { $_.signal.pattern })
        $codes = @($Rules | Where-Object { $_.signal.type -eq 'errorCode' } | ForEach-Object { $_.signal.values } | ForEach-Object { ConvertTo-AdHexCode $_ } | Select-Object -Unique)
        $analysis.textSignals = Find-AdTextSignals -Root $root -Patterns $patterns -ErrorCodes $codes

        if ($Config.useCommunityDiagnosticsScript -and $ext -eq '.cab' -and (Get-Command -Name 'Get-AutopilotDiagnosticsCommunity' -ErrorAction SilentlyContinue)) {
            try {
                $out = & Get-AutopilotDiagnosticsCommunity -CABFile $local *>&1 | Out-String
                $analysis.communityOutput = if ($out.Length -gt 20000) { $out.Substring(0, 20000) + '...' } else { $out }
            }
            catch { $analysis.communityOutput = "Get-AutopilotDiagnosticsCommunity failed: $($_.Exception.Message)" }
        }

        if (-not $regFiles -and -not $evtxFiles -and -not $analysis.textSignals) {
            $analysis.status = 'warning'
            $analysis.message = 'No MDMDiagReport_RegistryDump.Reg, Autopilot event log or matching log lines were found in this archive.'
        }
        # Findings for the log on its own (also shown when no deployment matches)
        $ev = Get-AdLogEvidence $analysis
        $analysis.findings = Find-AdRuleMatches -Evidence $ev -Rules $Rules
    }
    catch {
        $analysis.status = 'error'
        $analysis.message = Protect-AdLogText $_.Exception.Message
        Write-AdLog -Level WARN -Message "Log analysis failed: $($analysis.message)"
    }
    finally {
        Remove-AdTempFolder $temp
    }
    return $analysis
}
