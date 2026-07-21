<#
.SYNOPSIS
Registers a Windows Scheduled Task that runs a toolbox script on a daily schedule.
.DESCRIPTION
Wraps New-ScheduledTaskAction / New-ScheduledTaskTrigger / New-ScheduledTaskPrincipal /
Register-ScheduledTask to create a daily task that launches a given PowerShell script (for
example scheduled-tasks\Example-DailyReporting.ps1) under the SYSTEM account. Intended for
unattended, app-only-auth scenarios; interactive/delegated auth will not work under SYSTEM.
.PARAMETER TaskName
Name to register the scheduled task under in Task Scheduler.
.PARAMETER ScriptPath
Full path to the .ps1 script the task should execute.
.PARAMETER Arguments
Additional command-line arguments to pass to the script.
.PARAMETER StartTime
Daily start time for the task, in HH:mm (24-hour) format.
.PARAMETER PowerShellExecutable
PowerShell executable used to run the script (e.g. 'powershell.exe' for Windows PowerShell 5.1
or 'pwsh.exe' for PowerShell 7+). The toolbox targets PowerShell 7, so 'pwsh.exe' is recommended
if it is installed and on PATH for the SYSTEM account.
.PARAMETER RunAsUserId
Account the scheduled task principal runs as.
.EXAMPLE
.\scheduled-tasks\Register-AdminToolboxScheduledTask.ps1 -TaskName 'M365Toolbox-DailyReporting' -ScriptPath 'C:\Tools\M365-Admin-Toolbox\scheduled-tasks\Example-DailyReporting.ps1' -StartTime '02:00'
#>
param(
    [Parameter(Mandatory)][string]$TaskName,
    [Parameter(Mandatory)][string]$ScriptPath,
    [string]$Arguments = '',
    [string]$StartTime = '02:00'
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# PowerShell executable used to launch the scheduled script ('powershell.exe' or 'pwsh.exe').
$PowerShellExecutable = 'powershell.exe'
# Account the scheduled task principal runs under.
$RunAsUserId = 'SYSTEM'

if (-not (Test-Path -Path $ScriptPath)) {
    throw "ScriptPath not found: $ScriptPath"
}

try {
    $action = New-ScheduledTaskAction -Execute $PowerShellExecutable -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" $Arguments"
    $trigger = New-ScheduledTaskTrigger -Daily -At $StartTime
    $principal = New-ScheduledTaskPrincipal -UserId $RunAsUserId -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force
}
catch {
    throw "Failed to register scheduled task '$TaskName': $($_.Exception.Message)"
}
