<#
.SYNOPSIS
  Overlord Activity uploader: reads OverlordActivity.lua (SavedVariables), converts
  OverlordActivityDB.history + OverlordActivityDB.weekly to data/activity.json and
  pushes it to your GitHub Pages repo through the GitHub Contents API.

.DESCRIPTION
  Works with Windows PowerShell 5.1 and PowerShell 7+. No modules to install.
  The GitHub token is read from Windows Credential Manager (generic credential
  "overlord-activity-github", see set-token.ps1) or from the user environment
  variable OVERLORD_GH_TOKEN. The token is never written to disk and never logged.

  Modes:
    (default)  convert + upload once
    -Launch    start the game, wait until it exits, then upload
    -Watch     run forever (Task Scheduler "at log on"): upload every time the game exits
    -DryRun    convert only; writes the JSON to -OutFile and does not touch the network

.EXAMPLE
  .\overlord-upload.ps1 -DryRun -OutFile "$env:TEMP\activity.json"
.EXAMPLE
  .\overlord-upload.ps1 -Launch
#>
[CmdletBinding()]
param(
    [string]$WowDir = "",            # ...\World of Warcraft\_forever_   (auto-detected when empty)
    [string]$Account = "",           # folder name under WTF\Account     (auto-detected when only one has the file)
    [string]$SavedVariables = "",    # full path to OverlordActivity.lua (overrides WowDir/Account)
    [string]$Owner = "wowforeverguides",
    [string]$Repo = "overlord-activity",
    [string]$Branch = "main",
    [string]$RepoPath = "data/activity.json",
    [ValidateSet("Alias", "Keep")]
    [string]$CharacterNames = "Alias", # Alias = "Character 1", "Character 2"... on the public page
    [int]$Days = 0,                  # 0 = everything kept by the addon; N = last N days only
    [string]$GameExe = "",           # for -Launch; auto: Wow*.exe in WowDir
    [string]$OutFile = "",
    [switch]$Launch,
    [switch]$Watch,
    [switch]$DryRun,
    [switch]$Force,                  # upload even if unchanged since the last upload
    [string]$ConfigFile = "",        # optional JSON with any of the parameters above
    [string]$ApiBase = "https://api.github.com"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:CredTarget = "overlord-activity-github"
$script:StateDir = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "OverlordActivity"
if (-not $script:StateDir -or $script:StateDir -eq "OverlordActivity") { $script:StateDir = Join-Path ([IO.Path]::GetTempPath()) "OverlordActivity" }

#region config + logging -------------------------------------------------------
function Import-OAConfig {
    param([string]$Path)
    if (-not $Path) {
        $here = Join-Path $PSScriptRoot "overlord-upload.config.json"
        if (Test-Path -LiteralPath $here) { $Path = $here } else { return }
    }
    $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $cfg.PSObject.Properties) {
        if ($p.Name -match "token|secret|password") { throw "Config file must not contain a token ($($p.Name)). Use set-token.ps1 instead." }
        # explicit command-line parameters win over the config file
        if ($script:BoundParams.ContainsKey($p.Name)) { continue }
        Set-Variable -Scope Script -Name $p.Name -Value $p.Value
    }
}

function Write-OALog {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz"), $Message
    Write-Host $line
    try {
        if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $script:StateDir "upload.log") -Value $line -Encoding UTF8
    } catch { }
}
#endregion

#region Lua SavedVariables parser ----------------------------------------------
# Parses the subset of Lua that WoW writes to SavedVariables: assignments of
# tables / strings / numbers / booleans / nil, "-- [n]" comments, positional
# array entries, [key] = value and name = value entries.
# One match per significant token; whitespace and comments are skipped by the prefix.
$script:LuaTokenRegex = New-Object System.Text.RegularExpressions.Regex (@'
\G(?:\s+|--\[(?<lq>=*)\[[\s\S]*?\]\k<lq>\]|--[^\n]*)*(?<tok>"(?:[^"\\\n]|\\[\s\S])*"|'(?:[^'\\\n]|\\[\s\S])*'|\[(?<sq>=*)\[[\s\S]*?\]\k<sq>\]|-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)|[A-Za-z_][A-Za-z0-9_]*|[{}\[\]=,;]|.|$)
'@.Trim()), ([System.Text.RegularExpressions.RegexOptions]::Compiled)

function ConvertFrom-LuaString {
    param([string]$Raw)
    $q = $Raw[0]
    $s = $Raw.Substring(1, $Raw.Length - 2)
    if ($s.IndexOf('\') -lt 0) { return $s }
    $bytes = New-Object System.Collections.Generic.List[byte]
    $utf8 = [Text.Encoding]::UTF8
    $i = 0
    while ($i -lt $s.Length) {
        $c = $s[$i]
        if ($c -ne '\') {
            # copy a run of plain characters
            $j = $s.IndexOf('\', $i); if ($j -lt 0) { $j = $s.Length }
            $bytes.AddRange($utf8.GetBytes($s.Substring($i, $j - $i))); $i = $j; continue
        }
        $i++
        if ($i -ge $s.Length) { break }
        $e = $s[$i]
        switch -CaseSensitive ($e) {
            'n' { $bytes.Add(10); $i++ }
            't' { $bytes.Add(9); $i++ }
            'r' { $bytes.Add(13); $i++ }
            'a' { $bytes.Add(7); $i++ }
            'b' { $bytes.Add(8); $i++ }
            'f' { $bytes.Add(12); $i++ }
            'v' { $bytes.Add(11); $i++ }
            "`n" { $bytes.Add(10); $i++ }
            default {
                if ($e -match '[0-9]') {
                    $k = $i; $d = ""
                    while ($k -lt $s.Length -and $k -lt $i + 3 -and $s[$k] -match '[0-9]') { $d += $s[$k]; $k++ }
                    $bytes.Add([byte]([int]$d -band 255)); $i = $k
                } else {
                    $bytes.AddRange($utf8.GetBytes([string]$e)); $i++
                }
            }
        }
    }
    return $utf8.GetString($bytes.ToArray())
}

function ConvertFrom-LuaNumber {
    param([string]$Text)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Text -match '^-?0[xX]') {
        $neg = $Text.StartsWith("-"); $h = $Text -replace '^-?0[xX]', ''
        $v = [Convert]::ToInt64($h, 16); if ($neg) { $v = -$v }; return $v
    }
    if ($Text -match '^-?\d+$') {
        $l = 0L
        if ([long]::TryParse($Text, [Globalization.NumberStyles]::AllowLeadingSign, $inv, [ref]$l)) { return $l }
    }
    $d = [double]::Parse($Text, [Globalization.NumberStyles]::Float, $inv)
    if ([Math]::Floor($d) -eq $d -and [Math]::Abs($d) -lt 9e15) { return [long]$d }
    return $d
}

function ConvertFrom-LuaSavedVariables {
    <# Returns a Hashtable: global name -> value. Lua tables become case-sensitive
       Hashtables whose keys are [long] (integers), [double] or [string].
       Iterative (explicit stack) for speed on large files. #>
    param([Parameter(Mandatory)][string]$Text)
    # --- tokenize: kinds s=string S=long string n=number i=identifier, else the punctuation char ---
    $kinds = New-Object System.Collections.Generic.List[char]
    $vals = New-Object System.Collections.Generic.List[string]
    $gTok = $script:LuaTokenRegex.GroupNumberFromName("tok")
    $m = $script:LuaTokenRegex.Match($Text)
    while ($m.Success) {
        $g = $m.Groups[$gTok]
        $v = $g.Value
        if ($v.Length -eq 0) { break }          # end of input
        $c = $v[0]
        if ($c -eq '"' -or $c -eq "'") { $kinds.Add('s'); $vals.Add($v) }
        elseif ($c -eq '[' -and $v.Length -gt 1) {
            $lvl = 0; while ($v[1 + $lvl] -eq '=') { $lvl++ }
            $inner = $v.Substring(2 + $lvl, $v.Length - 4 - 2 * $lvl)
            if ($inner.StartsWith("`r`n")) { $inner = $inner.Substring(2) } elseif ($inner.StartsWith("`n")) { $inner = $inner.Substring(1) }
            $kinds.Add('S'); $vals.Add($inner)
        }
        elseif ([char]::IsDigit($c) -or (($c -eq '-' -or $c -eq '.') -and $v.Length -gt 1)) { $kinds.Add('n'); $vals.Add($v) }
        elseif ([char]::IsLetter($c) -or $c -eq '_') { $kinds.Add('i'); $vals.Add($v) }
        elseif ('{}[]=,;'.IndexOf($c) -ge 0) { $kinds.Add($c); $vals.Add($v) }
        else {
            $line = ($Text.Substring(0, $g.Index) -split "`n").Count
            throw "Unexpected character '$v' in SavedVariables at line $line"
        }
        $m = $m.NextMatch()
    }
    $TK = $kinds.ToArray(); $TV = $vals.ToArray(); $NT = $TK.Length
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $result = New-Object System.Collections.Hashtable
    $i = 0
    # frames of open tables
    $tStack = New-Object System.Collections.Generic.List[object]   # tables
    $kStack = New-Object System.Collections.Generic.List[object]   # key under which the child table goes into its parent
    $iStack = New-Object System.Collections.Generic.List[long]     # next positional index
    $NoKey = [object]::new()
    while ($i -lt $NT) {
        if ($TK[$i] -cne 'i' -or $i + 1 -ge $NT -or $TK[$i + 1] -cne '=') { throw "Expected 'name =' at token $i" }
        $gname = $TV[$i]; $i += 2
        $value = $null; $done = $false
        while (-not $done) {
            if ($i -ge $NT) { throw "Unexpected end of file" }
            $kind = $TK[$i]
            # inside a table: handle '}', separators and keys first
            $key = $NoKey
            if ($tStack.Count -gt 0) {
                if ($kind -ceq '}') {
                    $i++
                    $tbl = $tStack[$tStack.Count - 1]; $pk = $kStack[$kStack.Count - 1]
                    $tStack.RemoveAt($tStack.Count - 1); $kStack.RemoveAt($kStack.Count - 1); $iStack.RemoveAt($iStack.Count - 1)
                    if ($tStack.Count -eq 0) { $value = $tbl; $done = $true; break }
                    $parent = $tStack[$tStack.Count - 1]
                    if ([object]::ReferenceEquals($pk, $NoKey)) { $pi = $iStack[$iStack.Count - 1]; $parent[$pi] = $tbl; $iStack[$iStack.Count - 1] = $pi + 1 }
                    else { $parent[$pk] = $tbl }
                    if ($i -lt $NT -and ($TK[$i] -ceq ',' -or $TK[$i] -ceq ';')) { $i++ }
                    elseif ($i -ge $NT -or $TK[$i] -cne '}') { throw "Expected ',' or '}' after a table at token $i" }
                    continue
                }
                if ($kind -ceq '[') {
                    if ($i + 3 -ge $NT -or $TK[$i + 2] -cne ']' -or $TK[$i + 3] -cne '=') { throw "Bad [key] = at token $i" }
                    $kk = $TK[$i + 1]; $kv = $TV[$i + 1]
                    if ($kk -ceq 's') { $key = if ($kv.IndexOf('\') -lt 0) { $kv.Substring(1, $kv.Length - 2) } else { ConvertFrom-LuaString $kv } }
                    elseif ($kk -ceq 'n') { $key = ConvertFrom-LuaNumber $kv }
                    elseif ($kk -ceq 'S') { $key = $kv }
                    elseif ($kk -ceq 'i' -and ($kv -ceq 'true' -or $kv -ceq 'false')) { $key = ($kv -ceq 'true') }
                    else { throw "Unsupported table key at token $i" }
                    $i += 4
                } elseif ($kind -ceq 'i' -and $i + 1 -lt $NT -and $TK[$i + 1] -ceq '=') {
                    $key = $TV[$i]; $i += 2
                }
                if ($i -ge $NT) { throw "Unexpected end of file" }
                $kind = $TK[$i]
            }
            if ($kind -ceq '{') {
                $i++
                $tStack.Add((New-Object System.Collections.Hashtable)); $kStack.Add($key); $iStack.Add(1L)
                continue
            }
            # scalar
            $tokv = $TV[$i]
            switch -CaseSensitive ($kind) {
                's' { $sv = if ($tokv.IndexOf('\') -lt 0) { $tokv.Substring(1, $tokv.Length - 2) } else { ConvertFrom-LuaString $tokv } }
                'S' { $sv = $tokv }
                'n' {
                    $l = 0L
                    if ($tokv.Length -lt 18 -and $tokv.IndexOfAny([char[]]'.eExX') -lt 0 -and [long]::TryParse($tokv, [Globalization.NumberStyles]::AllowLeadingSign, $inv, [ref]$l)) { $sv = $l }
                    else { $sv = ConvertFrom-LuaNumber $tokv }
                }
                'i' {
                    if ($tokv -ceq 'true') { $sv = $true } elseif ($tokv -ceq 'false') { $sv = $false }
                    elseif ($tokv -ceq 'nil' -or $tokv -ceq 'inf' -or $tokv -ceq 'nan') { $sv = $null }
                    else { throw "Unsupported Lua expression '$tokv'" }
                }
                default { throw "Unexpected token '$tokv' at token $i" }
            }
            $i++
            if ($tStack.Count -eq 0) { $value = $sv; $done = $true; break }
            $tbl = $tStack[$tStack.Count - 1]
            if ([object]::ReferenceEquals($key, $NoKey)) { $pi = $iStack[$iStack.Count - 1]; if ($null -ne $sv) { $tbl[$pi] = $sv }; $iStack[$iStack.Count - 1] = $pi + 1 }
            elseif ($null -ne $sv -and $null -ne $key) { $tbl[$key] = $sv }
            if ($i -lt $NT -and ($TK[$i] -ceq ',' -or $TK[$i] -ceq ';')) { $i++ }
            elseif ($i -ge $NT -or $TK[$i] -cne '}') { throw "Expected ',' or '}' at token $i" }
        }
        $result[$gname] = $value
        if ($i -lt $NT -and $TK[$i] -ceq ';') { $i++ }
    }
    return $result
}
#endregion

#region conversion to the dashboard schema (overlord-activity/1) ---------------
function Get-T { param($Tbl, $Key) if ($Tbl -is [Collections.IDictionary] -and $Tbl.Contains($Key)) { return $Tbl[$Key] } return $null }
function Get-Tbl { param($Tbl, $Key) $v = Get-T $Tbl $Key; if ($v -is [Collections.IDictionary]) { return $v } return [ordered]@{} }
function Get-Num { param($Tbl, $Key) $v = Get-T $Tbl $Key; if ($v -is [long] -or $v -is [int]) { return [long]$v } if ($v -is [double]) { if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { return $null } return [long][Math]::Floor($v) } return $null }
function Get-Str { param($Tbl, $Key) $v = Get-T $Tbl $Key; if ($v -is [string]) { return $v } return $null }
function Clean-Name { param([string]$s) if ($null -eq $s) { return "" } return ($s -replace "[|,;:`r`n]", " ") }
function Get-Seq {
    # Lua array part 1..n (stops at the first gap, like ipairs)
    param($Tbl)
    $out = New-Object System.Collections.Generic.List[object]
    if (-not ($Tbl -is [Collections.IDictionary])) { return ,$out }
    $i = 1L
    while ($Tbl.Contains($i)) { $out.Add($Tbl[$i]); $i++ }
    return ,$out
}
function Get-SortedNumKeys {
    param($Tbl)
    $keys = New-Object System.Collections.Generic.List[long]
    foreach ($k in $Tbl.Keys) {
        if ($k -is [long]) { $keys.Add($k) }
        elseif ($k -is [double]) { $keys.Add([long]$k) }
        elseif ($k -is [string]) { $l = 0L; if ([long]::TryParse($k, [ref]$l)) { $keys.Add($l) } }
    }
    $arr = $keys.ToArray(); [Array]::Sort($arr); return ,$arr
}
function Get-SortedStrKeys {
    param($Tbl)
    $arr = @(foreach ($k in $Tbl.Keys) { [string]$k })
    [Array]::Sort($arr, [StringComparer]::Ordinal); return ,$arr
}
function Get-ByNumKey { param($Tbl, [long]$k) if ($Tbl.Contains($k)) { return $Tbl[$k] } if ($Tbl.Contains([string]$k)) { return $Tbl[[string]$k] } if ($Tbl.Contains([double]$k)) { return $Tbl[[double]$k] } return $null }

function ConvertTo-OAActivity {
    <# OverlordActivityDB (parsed) -> ordered hashtable in schema overlord-activity/1 #>
    param(
        [Parameter(Mandatory)]$Data,
        [long]$Generated,
        [string]$CharacterNames = "Alias",
        [int]$Days = 0
    )
    $h = Get-Tbl $Data "history"
    $b15 = Get-Tbl $h "b15"; $h60 = Get-Tbl $h "h60"
    $labels = Get-Tbl $h "labels"; $zoneOf = Get-Tbl $h "zoneOf"; $names = Get-Tbl $h "names"
    $from = $null
    if ($Days -gt 0) { $from = $Generated - [long]$Days * 86400; $from = $from - ($from % 3600) }

    $fights = [ordered]@{}; $zones = [ordered]@{}; $points = [ordered]@{}
    $charIdx = @{}; $chars = New-Object System.Collections.Generic.List[string]
    function KeyName([string]$key) {
        $n = Get-Str $zoneOf $key; if ($n) { return $n }
        $n = Get-Str $labels $key; if ($n) { return $n }
        return $key
    }
    function AddFight([string]$key) {
        if (-not $fights.Contains($key)) {
            $kind = if ($key.StartsWith("#")) { "w" } else { "f" }
            $fights[$key] = [ordered]@{ kind = $kind; name = (Clean-Name (KeyName $key)) }
        }
    }
    function CharIndex($ch) {
        if ($null -eq $ch -or $ch -isnot [string]) { $ch = "?" }
        if (-not $charIdx.ContainsKey($ch)) { $charIdx[$ch] = $chars.Count; $chars.Add($ch) }
        return $charIdx[$ch]
    }

    $buckets = New-Object System.Collections.Generic.List[object]
    foreach ($pair in @(@("h60", $h60, 3600), @("b15", $b15, 900))) {
        $tbl = $pair[1]; $dur = [long]$pair[2]
        foreach ($t in (Get-SortedNumKeys $tbl)) {
            if ($null -ne $from -and $t -lt $from) { continue }
            $b = Get-ByNumKey $tbl $t
            if ($b -isnot [Collections.IDictionary]) { continue }
            $o = [ordered]@{ t = $t; d = $dur; n = (Get-Num $b "n") }
            if ($null -eq $o.n) { $o.n = 0L }
            # same dictionary order as the in-game web export: fronts, own zones, points, featured, then the character
            $f = [ordered]@{}
            $fb = Get-Tbl $b "f"
            foreach ($k in (Get-SortedStrKeys $fb)) {
                $e = $fb[$k]
                AddFight $k
                $sum = Get-Num $e 2L; $max = Get-Num $e 1L; $cap = Get-Num $e 3L
                if ($null -eq $sum) { $sum = 0L }; if ($null -eq $max) { $max = 0L }; if ($null -eq $cap) { $cap = 0L }
                $f[$k] = @($sum, $max, $cap)
            }
            $pz = [ordered]@{}
            $pzb = Get-Tbl $b "pz"
            foreach ($m in (Get-SortedNumKeys $pzb)) {
                $ks = [string]$m
                if (-not $zones.Contains($ks)) {
                    $zn = Get-Str $names ("m" + $ks); if (-not $zn) { $zn = "Map " + $ks }
                    $zones[$ks] = Clean-Name $zn
                }
                $v = Get-Num @{ x = (Get-ByNumKey $pzb $m) } "x"; if ($null -eq $v) { $v = 0L }
                $pz[$ks] = $v
            }
            $cp = [ordered]@{}
            $cpb = Get-Tbl $b "cp"
            foreach ($k in (Get-SortedStrKeys $cpb)) {
                $pk = Clean-Name ($k -replace ":", "/")
                if (-not $points.Contains($pk)) {
                    $pn = Get-Str $names ("c" + $k); if (-not $pn) { $pn = $k }
                    $points[$pk] = Clean-Name $pn
                }
                $v = Get-Num $cpb $k; if ($null -eq $v) { $v = 0L }
                $cp[$pk] = $v
            }
            $ff = Get-Str $b "ff"
            if ($ff) { AddFight $ff }
            $ch = Get-Str $b "ch"
            $o.ch = if ($ch) { CharIndex $ch } else { $null }
            $o.ff = $ff
            $o.hk = Get-Num $b "hk"
            $o.f = $f; $o.pz = $pz; $o.cp = $cp
            $buckets.Add($o)
        }
    }
    $sessions = New-Object System.Collections.Generic.List[object]
    foreach ($s in (Get-Seq (Get-T $h "sessions"))) {
        $ss = Get-Num $s "s"; $se = Get-Num $s "e"
        if ($null -eq $ss -or $null -eq $se) { continue }
        if ($null -ne $from -and $se -lt $from) { continue }
        $sessions.Add([ordered]@{ s = $ss; e = $se; ch = (CharIndex (Get-Str $s "ch")) })
    }

    $weekly = $null
    $w = Get-T $Data "weekly"
    if ($w -is [Collections.IDictionary]) {
        $weeks = New-Object System.Collections.Generic.List[object]
        $wt = Get-Tbl $w "weeks"
        foreach ($cs in (Get-SortedNumKeys $wt)) {
            $e = Get-ByNumKey $wt $cs
            if ($e -isnot [Collections.IDictionary]) { continue }
            $src = Get-Str $e "src"; if ($null -eq $src) { $src = "" }
            $cap = Get-Num $e "cap"; if ($null -eq $cap -and $src -ne "live") { $cap = 0L }
            if ($src -eq "live") { $cap = $null }          # live weeks have no capture sum (spec: empty/0)
            $o = [ordered]@{ cs = $cs; src = (Clean-Name $src) }
            foreach ($fld in "total", "players") { $v = Get-Num $e $fld; if ($null -eq $v) { $v = 0L }; $o[$fld] = $v }
            $o.cap = $cap
            $o.zones = Get-Num $e "zones"
            foreach ($fld in "alli", "horde", "topKills") { $v = Get-Num $e $fld; if ($null -eq $v) { $v = 0L }; $o[$fld] = $v }
            # PRIVACY: topName (the week's best player) is deliberately not exported.
            $weeks.Add($o)
        }
        $factions = New-Object System.Collections.Generic.List[object]
        foreach ($f in (Get-Seq (Get-T $w "samples"))) {
            $ft = Get-Num $f "t"; if ($null -eq $ft) { continue }
            if ($null -ne $from -and $ft -lt $from) { continue }
            $a = Get-Num $f "a"; if ($null -eq $a) { $a = 0L }
            $hh = Get-Num $f "h"; if ($null -eq $hh) { $hh = 0L }
            $src = Get-Str $f "src"; if ($null -eq $src) { $src = "" }
            $factions.Add([ordered]@{ t = $ft; src = (Clean-Name $src); a = $a; h = $hh; u = (Get-Num $f "u"); n = (Get-Num $f "n") })
        }
        $guilds = New-Object System.Collections.Generic.List[object]
        $g = Get-Tbl $w "guilds"
        $gcs = Get-Num $g "cs"; if ($null -eq $gcs) { $gcs = 0L }
        $rank = 1L
        foreach ($gl in (Get-Seq (Get-T $g "list"))) {
            $k = Get-Num $gl "kills"; if ($null -eq $k) { $k = 0L }
            $guilds.Add([ordered]@{ cs = $gcs; rank = $rank; kills = $k; faction = (Clean-Name (Get-Str $gl "faction")); name = (Clean-Name (Get-Str $gl "name")) })
            $rank++
        }
        $me = $null
        $mt = Get-T $w "me"
        if ($mt -is [Collections.IDictionary] -and $null -ne (Get-Num $mt "rank")) {
            # PRIVACY: me.name is not exported (only the rank numbers).
            $mcs = Get-Num $mt "cs"; if ($null -eq $mcs) { $mcs = 0L }
            $mk = Get-Num $mt "kills"; if ($null -eq $mk) { $mk = 0L }
            $mp = Get-Num $mt "players"; if ($null -eq $mp) { $mp = 0L }
            $me = [ordered]@{ cs = $mcs; rank = (Get-Num $mt "rank"); kills = $mk; kb = (Get-Num $mt "kb"); players = $mp }
        }
        $frontLast = New-Object System.Collections.Generic.List[object]
        foreach ($ev in (Get-Seq (Get-T $w "events"))) {
            $ef = Get-Str $ev "f"; $et = Get-Num $ev "t"
            if (-not $ef -or $null -eq $et) { continue }
            if ($null -ne $from -and $et -lt $from) { continue }
            AddFight $ef
            $frontLast.Add([ordered]@{ front = $ef; t = $et })
        }
        $victory = $null
        $lc = Get-T $w "lastCampaign"
        if ($lc -is [Collections.IDictionary] -and (Get-Str $lc "frontId")) {
            $vf = Get-Str $lc "frontId"; AddFight $vf
            $victory = [ordered]@{ front = $vf }
            foreach ($fld in @(@("ally", "ally"), @("enemy", "enemy"), @("total", "total"))) { $v = Get-Num $lc $fld[0]; if ($null -eq $v) { $v = 0L }; $victory[$fld[1]] = $v }
            $victory.faction = Clean-Name (Get-Str $lc "faction")
        }
        $weekly = [ordered]@{ weeks = $weeks; factions = $factions; guilds = $guilds; me = $me; frontLast = $frontLast; victory = $victory }
    }

    # PRIVACY: your own character names are replaced by "Character N" unless -CharacterNames Keep.
    $outChars = New-Object System.Collections.Generic.List[string]
    $n = 0
    foreach ($c in $chars) {
        if ($CharacterNames -eq "Keep" -or $c -eq "multiple" -or $c -eq "?") { $outChars.Add((Clean-Name $c)) }
        else { $n++; $outChars.Add("Character $n") }
    }

    return [ordered]@{
        schema    = "overlord-activity/1"
        sample    = $false
        source    = "savedvariables"
        generated = $Generated
        step      = 900L
        names     = [ordered]@{ fights = $fights; zones = $zones; points = $points }
        chars     = $outChars
        buckets   = $buckets
        sessions  = $sessions
        weekly    = $weekly
    }
}

function ConvertTo-OAJson {
    <# Deterministic compact JSON (identical on PowerShell 5.1 and 7). #>
    param($Value)
    $sb = New-Object System.Text.StringBuilder
    Write-OAJsonValue $sb $Value
    return $sb.ToString()
}
function Write-OAJsonValue([System.Text.StringBuilder]$sb, $v) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $v) { [void]$sb.Append("null"); return }
    if ($v -is [bool]) { [void]$sb.Append($(if ($v) { "true" } else { "false" })); return }
    if ($v -is [long] -or $v -is [int]) { [void]$sb.Append(([long]$v).ToString($inv)); return }
    if ($v -is [double]) { [void]$sb.Append($v.ToString("R", $inv)); return }
    if ($v -is [string]) { Write-OAJsonString $sb $v; return }
    if ($v -is [Collections.IDictionary]) {
        [void]$sb.Append("{"); $first = $true
        foreach ($k in $v.Keys) {
            if (-not $first) { [void]$sb.Append(",") }; $first = $false
            Write-OAJsonString $sb ([string]$k); [void]$sb.Append(":"); Write-OAJsonValue $sb $v[$k]
        }
        [void]$sb.Append("}"); return
    }
    if ($v -is [Collections.IEnumerable]) {
        [void]$sb.Append("["); $first = $true
        foreach ($x in $v) { if (-not $first) { [void]$sb.Append(",") }; $first = $false; Write-OAJsonValue $sb $x }
        [void]$sb.Append("]"); return
    }
    Write-OAJsonString $sb ([string]$v)
}
function Write-OAJsonString([System.Text.StringBuilder]$sb, [string]$s) {
    [void]$sb.Append('"')
    if ($s -cnotmatch '[\x00-\x1f"\\<>&\u2028\u2029]') { [void]$sb.Append($s); [void]$sb.Append('"'); return }
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($c -eq 10) { [void]$sb.Append('\n') }
        elseif ($c -eq 13) { [void]$sb.Append('\r') }
        elseif ($c -eq 9) { [void]$sb.Append('\t') }
        elseif ($c -lt 32 -or $ch -eq '<' -or $ch -eq '>' -or $ch -eq '&' -or ($c -ge 0x2028 -and $c -le 0x2029)) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
}
#endregion

#region locating files -------------------------------------------------------------
function Find-OAWowDir {
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($rk in "HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft", "HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft") {
        try {
            $ip = (Get-ItemProperty -Path $rk -ErrorAction Stop).InstallPath
            if ($ip) { $root = Split-Path -Parent ($ip.TrimEnd('\', '/')); $cands.Add((Join-Path $root "_forever_")) }
        } catch { }
    }
    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, "C:\Program Files (x86)", "C:\Program Files", "C:\Games", "D:\Games", "D:\")) {
        if ($pf) { $cands.Add((Join-Path (Join-Path $pf "World of Warcraft") "_forever_")) }
    }
    foreach ($c in $cands) { if (Test-Path -LiteralPath (Join-Path $c "WTF")) { return $c } }
    throw "Could not find the World of Warcraft\_forever_ folder. Pass -WowDir 'X:\...\World of Warcraft\_forever_' (or set WowDir in overlord-upload.config.json)."
}

function Resolve-OASavedVariables {
    if ($script:SavedVariables) {
        if (-not (Test-Path -LiteralPath $script:SavedVariables)) { throw "SavedVariables file not found: $($script:SavedVariables)" }
        return $script:SavedVariables
    }
    if (-not $script:WowDir) { $script:WowDir = Find-OAWowDir }
    $acctRoot = Join-Path (Join-Path $script:WowDir "WTF") "Account"
    if ($script:Account) {
        $p = Join-Path (Join-Path (Join-Path $acctRoot $script:Account) "SavedVariables") "OverlordActivity.lua"
        if (-not (Test-Path -LiteralPath $p)) { throw "No OverlordActivity.lua for account '$($script:Account)' (looked in $p)." }
        return $p
    }
    $found = @(Get-ChildItem -LiteralPath $acctRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        Test-Path -LiteralPath (Join-Path (Join-Path $_.FullName "SavedVariables") "OverlordActivity.lua") })
    if ($found.Count -eq 1) { return (Join-Path (Join-Path $found[0].FullName "SavedVariables") "OverlordActivity.lua") }
    if ($found.Count -eq 0) { throw "No WTF\Account\<ACCOUNT>\SavedVariables\OverlordActivity.lua under $($script:WowDir). Log in once with the addon enabled, then exit the game." }
    throw ("More than one account has OverlordActivity.lua: " + (($found | ForEach-Object { $_.Name }) -join ", ") + ". Pass -Account <name> (or set Account in the config file).")
}
#endregion

#region token -------------------------------------------------------------------
function Initialize-OACredApi {
    if ("OACred" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OACred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
        public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredReadW(string target, int type, int flags, out IntPtr cred);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWriteW(ref CREDENTIAL cred, int flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDeleteW(string target, int type, int flags);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr p);
    public static string Read(string target) {
        IntPtr p;
        if (!CredReadW(target, 1, 0, out p)) return null;
        try {
            CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            if (c.CredentialBlobSize <= 0 || c.CredentialBlob == IntPtr.Zero) return null;
            return Marshal.PtrToStringUni(c.CredentialBlob, c.CredentialBlobSize / 2);
        } finally { CredFree(p); }
    }
    public static void Write(string target, string user, string secret) {
        CREDENTIAL c = new CREDENTIAL();
        c.Type = 1; c.TargetName = target; c.UserName = user; c.Persist = 2;
        c.CredentialBlobSize = secret.Length * 2;
        c.CredentialBlob = Marshal.StringToCoTaskMemUni(secret);
        try { if (!CredWriteW(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
        finally { Marshal.ZeroFreeCoTaskMemUnicode(c.CredentialBlob); }
    }
    public static bool Delete(string target) { return CredDeleteW(target, 1, 0); }
}
'@
}

function Test-OAIsWindows {
    if ($PSVersionTable.PSEdition -eq "Desktop") { return $true }
    $v = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
    return ($v -and $v.Value)
}

function Get-OAToken {
    if (Test-OAIsWindows) {
        try {
            Initialize-OACredApi
            $t = [OACred]::Read($script:CredTarget)
            if ($t) { return $t.Trim() }
        } catch { Write-OALog "Credential Manager not readable; trying OVERLORD_GH_TOKEN." }
        $t = [Environment]::GetEnvironmentVariable("OVERLORD_GH_TOKEN", "User")
        if ($t) { return $t.Trim() }
    }
    $t = [Environment]::GetEnvironmentVariable("OVERLORD_GH_TOKEN")
    if ($t) { return $t.Trim() }
    throw "No GitHub token. Run set-token.ps1 (Windows Credential Manager, target '$($script:CredTarget)') or set the user environment variable OVERLORD_GH_TOKEN."
}
#endregion

#region upload -------------------------------------------------------------------
function Get-OAGitBlobSha([byte[]]$Bytes) {
    $hdr = [Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $all = New-Object byte[] ($hdr.Length + $Bytes.Length)
    [Array]::Copy($hdr, $all, $hdr.Length); [Array]::Copy($Bytes, 0, $all, $hdr.Length, $Bytes.Length)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    return (($sha1.ComputeHash($all) | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-OAHttpStatus($err) {
    try { return [int]$err.Exception.Response.StatusCode } catch { return 0 }
}

function Publish-OAActivity {
    param([byte[]]$Bytes, [string]$Token)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent"           = "overlord-activity-uploader"
    }
    $dir = ($script:RepoPath -replace '\\', '/')
    $leaf = $dir.Substring($dir.LastIndexOf('/') + 1)
    $parent = if ($dir.Contains('/')) { $dir.Substring(0, $dir.LastIndexOf('/')) } else { "" }
    # The token is only ever sent to GitHub (or a local test server).
    if ($script:ApiBase -notmatch '^(https://api\.github\.com|http://(127\.0\.0\.1|localhost)(:\d+)?)/?$') { throw "ApiBase must be https://api.github.com." }
    $api = "$($script:ApiBase.TrimEnd('/'))/repos/$($script:Owner)/$($script:Repo)/contents"
    # Look the file up through its folder listing (works for files of any size).
    $remoteSha = $null
    try {
        $listing = Invoke-RestMethod -Method Get -Uri ("$api/$parent" + "?ref=$($script:Branch)") -Headers $headers
        foreach ($item in @($listing)) { if ($item.name -eq $leaf) { $remoteSha = $item.sha } }
    } catch {
        $code = Get-OAHttpStatus $_
        if ($code -eq 401) { throw "GitHub rejected the token (401). Create a new fine-grained token and run set-token.ps1 again." }
        if ($code -eq 403) { throw "GitHub refused access (403). The token needs Repository access = only $($script:Owner)/$($script:Repo), permission Contents: Read and write." }
        if ($code -ne 404) { throw "GitHub lookup failed (HTTP $code)." }
    }
    $localSha = Get-OAGitBlobSha $Bytes
    if ($remoteSha -eq $localSha) { Write-OALog "Remote $($script:RepoPath) is already up to date ($localSha)."; return $false }
    $body = [ordered]@{
        message = "Update activity data " + (Get-Date).ToString("yyyy-MM-dd HH:mm zzz")
        content = [Convert]::ToBase64String($Bytes)
        branch  = $script:Branch
    }
    if ($remoteSha) { $body.sha = $remoteSha }
    $json = ConvertTo-OAJson $body
    try {
        $res = Invoke-RestMethod -Method Put -Uri "$api/$dir" -Headers $headers -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($json))
    } catch {
        $code = Get-OAHttpStatus $_
        if ($code -eq 409) { throw "GitHub reported a conflict (409): the file changed meanwhile. Run the upload again." }
        if ($code -eq 401 -or $code -eq 403) { throw "GitHub refused the upload (HTTP $code). Check the token's repository access and Contents: Read and write." }
        if ($code -eq 404) { throw "Repository $($script:Owner)/$($script:Repo) or branch '$($script:Branch)' not found, or the token cannot see it (404)." }
        throw "GitHub upload failed (HTTP $code)."
    }
    Write-OALog ("Uploaded {0} bytes to {1}/{2}:{3} (commit {4})." -f $Bytes.Length, $script:Owner, $script:Repo, $script:RepoPath, $res.commit.sha)
    return $true
}

function Invoke-OAUpload {
    $sv = Resolve-OASavedVariables
    $fi = Get-Item -LiteralPath $sv
    $text = [IO.File]::ReadAllText($fi.FullName, [Text.Encoding]::UTF8)
    $vars = ConvertFrom-LuaSavedVariables -Text $text
    if (-not $vars.Contains("OverlordActivityDB") -or $vars["OverlordActivityDB"] -isnot [Collections.IDictionary]) { throw "OverlordActivity.lua has no OverlordActivityDB table." }
    $gen = [long][Math]::Floor(([DateTimeOffset]$fi.LastWriteTimeUtc).ToUnixTimeSeconds())
    $data = ConvertTo-OAActivity -Data $vars["OverlordActivityDB"] -Generated $gen -CharacterNames $script:CharacterNames -Days $script:Days
    $json = ConvertTo-OAJson $data
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($json)
    Write-OALog ("Converted {0}: {1} buckets, {2} sessions, {3} weeks." -f $fi.Name, $data.buckets.Count, $data.sessions.Count, $(if ($data.weekly) { $data.weekly.weeks.Count } else { 0 }))
    if ($script:OutFile) {
        $outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($script:OutFile)
        [IO.File]::WriteAllBytes($outPath, $bytes); Write-OALog "Wrote $outPath."
    }
    if ($script:DryRun) { return }
    $stateFile = Join-Path $script:StateDir "last-upload.sha"
    $sha = Get-OAGitBlobSha $bytes
    if (-not $script:Force -and (Test-Path -LiteralPath $stateFile) -and ((Get-Content -LiteralPath $stateFile -Raw).Trim() -eq $sha)) {
        Write-OALog "No change since the last upload; nothing to do."; return
    }
    $token = Get-OAToken
    try { [void](Publish-OAActivity -Bytes $bytes -Token $token) } finally { $token = $null }
    if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
    Set-Content -LiteralPath $stateFile -Value $sha -Encoding ASCII
}
#endregion

#region launch / watch -----------------------------------------------------------
function Get-OAGameProcesses {
    $root = (Resolve-Path -LiteralPath $script:WowDir).Path.TrimEnd('\') + '\'
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) } catch { $false } })
}

function Wait-OAGameExit {
    while ((Get-OAGameProcesses).Count -gt 0) { Start-Sleep -Seconds 5 }
    # give the client a moment to finish writing SavedVariables
    Start-Sleep -Seconds 10
}

function Start-OAGame {
    if (-not $script:WowDir) { $script:WowDir = Find-OAWowDir }
    $exe = $script:GameExe
    if (-not $exe) {
        $c = @(Get-ChildItem -LiteralPath $script:WowDir -Filter "Wow*.exe" -File | Where-Object { $_.Name -notmatch "Launcher|Error|Setup|Uninstall|Voice|Crash" } | Sort-Object { $_.Name.Length })
        if ($c.Count -eq 0) { throw "No Wow*.exe in $($script:WowDir). Pass -GameExe <full path>." }
        $exe = $c[0].FullName
    }
    Write-OALog "Starting $exe"
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) | Out-Null
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-OAGameProcesses).Count -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
}
#endregion

#region main ---------------------------------------------------------------------
$script:BoundParams = $PSBoundParameters
if ($MyInvocation.InvocationName -ne '.') {
    Import-OAConfig -Path $ConfigFile
    try {
        if ($Launch) {
            Start-OAGame
            Write-OALog "Waiting for the game to close..."
            Wait-OAGameExit
            Invoke-OAUpload
        } elseif ($Watch) {
            if (-not $script:WowDir) { $script:WowDir = Find-OAWowDir }
            Write-OALog "Watching $($script:WowDir) - uploads after the game closes."
            try { Invoke-OAUpload } catch { Write-OALog "Upload failed: $($_.Exception.Message)" }
            while ($true) {
                while ((Get-OAGameProcesses).Count -eq 0) { Start-Sleep -Seconds 15 }
                Write-OALog "Game started."
                Wait-OAGameExit
                Write-OALog "Game closed."
                try { Invoke-OAUpload } catch { Write-OALog "Upload failed: $($_.Exception.Message)" }
            }
        } else {
            Invoke-OAUpload
        }
    } catch {
        Write-OALog "ERROR: $($_.Exception.Message)"
        exit 1
    }
}
#endregion
