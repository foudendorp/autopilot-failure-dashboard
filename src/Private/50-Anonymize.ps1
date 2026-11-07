# Anonymization: masks user names, device names and serial numbers everywhere in an API payload
# (including free text such as failure details and log lines) and in exports.
# Pseudonyms are stable for the lifetime of the server process (HMAC with a random per-run key),
# so the same device keeps the same alias across views, but aliases can't be reversed.

function Get-AdPseudonym {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][byte[]]$Key)
    $h = [System.Security.Cryptography.HMACSHA256]::HashData($Key, [System.Text.Encoding]::UTF8.GetBytes($Value.ToUpperInvariant()))
    return '{0}-{1}' -f $Prefix, ([Convert]::ToHexString($h, 0, 3))
}

function Get-AdSensitiveValues {
    <# Collects the values to mask from deployments and log analyses. #>
    param([object[]]$Deployments, [object[]]$LogAnalyses, $Account)
    $map = [ordered]@{}
    $add = {
        param($v, $prefix)
        if ($v -is [string] -and $v.Trim().Length -ge 3 -and -not $map.Contains($v)) { $map[$v] = $prefix }
    }
    foreach ($d in @($Deployments)) {
        if ($null -eq $d) { continue }
        & $add $d.upn 'user'
        & $add $d.deviceName 'device'
        & $add $d.serial 'SN'
    }
    foreach ($l in @($LogAnalyses)) {
        if ($null -eq $l) { continue }
        & $add $l.serialNumber 'SN'
    }
    if ($Account) {
        & $add ([string]$Account.upn) 'user'
        & $add ([string]$Account.name) 'user'
    }
    return $map
}

function Protect-AdJson {
    <#
      Masks a JSON document in one pass. Works on the JSON text so no field can be missed;
      pseudonyms only contain [A-Za-z0-9-] so they can't break the JSON structure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SensitiveValues,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $out = $Json
    # Longest first so "PC-123-A" is replaced before "PC-123". String.Replace (ordinal, ignore case)
    # is vectorised and much faster than a regex alternation over hundreds of values.
    foreach ($value in @($SensitiveValues.Keys | Sort-Object Length -Descending)) {
        # JSON-escaped form exactly as ConvertTo-Json (Newtonsoft) wrote it into $Json.
        $encoded = [Newtonsoft.Json.JsonConvert]::ToString([string]$value).Trim('"')
        $alias = Get-AdPseudonym -Value $value -Prefix $SensitiveValues[$value] -Key $Key
        $out = $out.Replace($encoded, $alias, [StringComparison]::OrdinalIgnoreCase)
    }
    # Any remaining e-mail address / UPN in free text.
    return [regex]::Replace($out, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m) Get-AdPseudonym -Value $m.Value -Prefix 'user' -Key $Key
        }.GetNewClosure())
}

function Protect-AdPayload {
    <# Returns a masked deep copy of $Payload (see Protect-AdJson). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SensitiveValues,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $json = Protect-AdJson -Json ($Payload | ConvertTo-Json -Depth 30 -Compress) -SensitiveValues $SensitiveValues -Key $Key
    return ($json | ConvertFrom-Json -Depth 30 -AsHashtable)
}
