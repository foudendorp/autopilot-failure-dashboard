# Exports (CSV / JSON). Only generated on explicit request after the sensitivity warning.
# The export is built in memory and handed to the browser; nothing is written to disk.

function Protect-AdCsvCell {
    <# Prevents CSV/formula injection when the file is opened in Excel. #>
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { (@($Value) -join '; ') } else { [string]$Value }
    if ($s -match '^[=\+\-@\t\r]') { $s = "'" + $s }
    return $s
}

function New-AdExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('csv', 'json')][string]$Format,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Deployments,
        [object[]]$Improvements = @(),
        [hashtable]$Meta = @{}
    )
    $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    if ($Format -eq 'json') {
        $doc = [ordered]@{
            exportedUtc  = [datetime]::UtcNow.ToString('o')
            sensitivity  = 'Contains Intune tenant data. Handle according to your organisation''s data classification.'
            anonymized   = [bool]$Meta.anonymized
            meta         = $Meta
            deployments  = $Deployments
            improvements = $Improvements
        }
        $text = $doc | ConvertTo-Json -Depth 30
        return [pscustomobject]@{ FileName = "autopilot-analysis-$stamp.json"; ContentType = 'application/json'; Bytes = [System.Text.Encoding]::UTF8.GetBytes($text) }
    }
    $rows = foreach ($d in $Deployments) {
        $top = @($d.findings) | Select-Object -First 1
        [pscustomobject][ordered]@{
            Date             = Protect-AdCsvCell $d.eventDateTime
            Status           = Protect-AdCsvCell $d.status
            Phase            = Protect-AdCsvCell $d.phase
            Flow             = Protect-AdCsvCell $d.flow
            DeviceName       = Protect-AdCsvCell $d.deviceName
            SerialNumber     = Protect-AdCsvCell $d.serial
            User             = Protect-AdCsvCell $d.upn
            Manufacturer     = Protect-AdCsvCell $d.manufacturer
            Model            = Protect-AdCsvCell $d.model
            Profile          = Protect-AdCsvCell $d.profile
            IntendedProfile  = Protect-AdCsvCell $d.intendedProfile
            DurationMinutes  = if ($d.durationSec) { [math]::Round($d.durationSec / 60, 1) } else { '' }
            ErrorCodes       = Protect-AdCsvCell $d.errorCodes
            FailedItems      = Protect-AdCsvCell (@($d.failedItems) | ForEach-Object { $_.name })
            TopFindingRule   = Protect-AdCsvCell $(if ($top) { $top.ruleId } else { '' })
            TopFindingLabel  = Protect-AdCsvCell $(if ($top) { "$($top.label) ($($top.confidence) confidence)" } else { '' })
            TopFindingCause  = Protect-AdCsvCell $(if ($top) { $top.likelyCause } else { '' })
            RecommendedFix   = Protect-AdCsvCell $(if ($top) { $top.recommendedFix } else { '' })
            StructuralAction = Protect-AdCsvCell $(if ($top) { $top.structuralAction } else { '' })
            OtherFindings    = Protect-AdCsvCell (@($d.findings) | Select-Object -Skip 1 | ForEach-Object { $_.ruleId })
        }
    }
    $csv = if ($rows) { ($rows | ConvertTo-Csv -NoTypeInformation -UseQuotes Always) -join "`r`n" } else { '"No deployments in the current selection"' }
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    return [pscustomobject]@{ FileName = "autopilot-analysis-$stamp.csv"; ContentType = 'text/csv; charset=utf-8'; Bytes = $bom + [System.Text.Encoding]::UTF8.GetBytes($csv) }
}
