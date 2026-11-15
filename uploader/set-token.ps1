<#
.SYNOPSIS
  Stores your fine-grained GitHub token for the Overlord Activity uploader in Windows
  Credential Manager (generic credential "overlord-activity-github"). The token is typed
  hidden, kept only in Credential Manager, and never written to a file.
.EXAMPLE
  .\set-token.ps1            # store or replace the token
  .\set-token.ps1 -Test      # check that the stored token can see the repo (no changes)
  .\set-token.ps1 -Remove    # delete the stored token
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$Test,
    [string]$Owner = "wowforeverguides",
    [string]$Repo = "overlord-activity"
)
$ErrorActionPreference = "Stop"
$want = @{ Owner = $Owner; Repo = $Repo; Remove = [bool]$Remove; Test = [bool]$Test }
. (Join-Path $PSScriptRoot "overlord-upload.ps1")   # loads the helpers only (nothing runs)
$Owner = $want.Owner; $Repo = $want.Repo; $Remove = $want.Remove; $Test = $want.Test
Initialize-OACredApi
$target = "overlord-activity-github"

if ($Remove) {
    if ([OACred]::Delete($target)) { Write-Host "Removed the stored token." } else { Write-Host "No stored token found." }
    return
}
if (-not $Test) {
    $sec = Read-Host -AsSecureString "Paste the fine-grained GitHub token (input is hidden)"
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr).Trim()
        if ($plain.Length -lt 20) { throw "That does not look like a GitHub token." }
        if ($plain -notmatch '^github_pat_') { Write-Warning "Expected a fine-grained token (starts with github_pat_). Classic tokens can reach all your repos; a fine-grained one limited to $Owner/$Repo is safer." }
        [OACred]::Write($target, "github-token", $plain)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr); $plain = $null
    }
    Write-Host "Token stored in Windows Credential Manager as '$target'."
}
# read-only check: can the token see the repository?
$tok = [OACred]::Read($target)
if (-not $tok) { throw "No token stored." }
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo" -Headers @{ Authorization = "Bearer $tok"; "User-Agent" = "overlord-activity-uploader"; Accept = "application/vnd.github+json" }
    $push = $false; try { $push = [bool]$r.permissions.push } catch { }
    Write-Host ("Token works: it can see {0}. Write access: {1}." -f $r.full_name, $(if ($push) { "yes" } else { "NO - give it Contents: Read and write" }))
} catch {
    Write-Warning ("The token could not read {0}/{1} (HTTP {2}). Check the repository access and permissions." -f $Owner, $Repo, (Get-OAHttpStatus $_))
} finally { $tok = $null }
