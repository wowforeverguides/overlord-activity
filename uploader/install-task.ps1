<#
  NOTE: automatic uploads are approved. Watch mode (the default) is the recommended setup.
.SYNOPSIS
  Registers (or removes) a Windows Task Scheduler job that runs the uploader for you.

  -Mode Watch     (default) starts at log on, waits in the background and uploads each time
                  the game closes. Uses almost no CPU (checks every 15 seconds).
  -Mode Interval  runs every -Minutes minutes and uploads only if the data changed.
.EXAMPLE
  .\install-task.ps1
  .\install-task.ps1 -Mode Interval -Minutes 60
  .\install-task.ps1 -Remove
#>
[CmdletBinding()]
param(
    [ValidateSet("Watch", "Interval")][string]$Mode = "Watch",
    [int]$Minutes = 60,
    [switch]$Remove,
    [string]$TaskName = "Overlord Activity upload"
)
$ErrorActionPreference = "Stop"
if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task '$TaskName' (if it existed)."
    return
}
$uploader = Join-Path $PSScriptRoot "overlord-upload.ps1"
if (-not (Test-Path -LiteralPath $uploader)) { throw "overlord-upload.ps1 must be in the same folder as this script." }
$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uploader`""
if ($Mode -eq "Watch") { $argLine += " -Watch" }
$action = New-ScheduledTaskAction -Execute $psExe -Argument $argLine -WorkingDirectory $PSScriptRoot
if ($Mode -eq "Watch") {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
} else {
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew -StartWhenAvailable
}
# Runs as you, only when you are logged on, without admin rights (needed to read your Credential Manager).
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Registered '$TaskName' ($Mode). Log: $env:LOCALAPPDATA\OverlordActivity\upload.log"
if ($Mode -eq "Watch") { Start-ScheduledTask -TaskName $TaskName; Write-Host "Started it now as well." }
