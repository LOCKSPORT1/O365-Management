<#
.SYNOPSIS
    Device-side Intune check-in trigger. Deploy via any RMM as SYSTEM.

.DESCRIPTION
    Companion to Invoke-FleetIntuneSync.ps1. The Graph-side sync relies on a
    WNS push reaching the device; if a device is behind a network that blocks
    the push channel, the request queues until the next natural check-in.
    This script fires the check-in from the DEVICE side instead, by starting
    the OMA-DM 'PushLaunch' scheduled task directly.

    Use cases:
      - Belt-and-suspenders after a Graph-side fleet sync
      - Environments where WNS is unreliable or blocked
      - RMM one-click "make this device talk to Intune NOW" tool

.NOTES
    Run as   : SYSTEM (RMM deployment) or elevated admin
    Exit 0   : task fired (or no MDM enrollment found — see output)
    Exit 1   : task exists but failed to start
#>

[CmdletBinding()]
param()

#region Configuration
$TaskPath = '\Microsoft\Windows\EnterpriseMgmt\*'
$TaskName = 'PushLaunch'
#endregion Configuration

$tasks = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue

if (-not $tasks) {
    Write-Output "No '$TaskName' task found under $TaskPath — device may not be MDM-enrolled."
    exit 0
}

$errors = 0
foreach ($t in $tasks) {
    try {
        $t | Start-ScheduledTask -ErrorAction Stop
        Write-Output "Fired: $($t.TaskPath)$($t.TaskName)"
    }
    catch {
        Write-Output "FAILED to start $($t.TaskPath)$($t.TaskName): $($_.Exception.Message)"
        $errors++
    }
}

exit $(if ($errors) { 1 } else { 0 })
