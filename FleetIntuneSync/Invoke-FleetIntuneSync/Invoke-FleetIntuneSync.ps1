<#
.SYNOPSIS
    Fleet-wide Intune device sync via Microsoft Graph.

.DESCRIPTION
    Sends a Sync (check-in) request to every Intune-managed device matching the
    configured filters. Useful after policy/assignment changes when you want the
    fleet to re-evaluate promptly instead of waiting for the normal ~8-hour
    check-in cadence.

    Design notes:
 - Self-connecting: prompts for interactive Graph sign-in if no session
        with the required scope exists. No app registration required.
 - Idempotent and read-safe by default: run with -WhatIfMode first to see
        exactly which devices would be targeted.
 - Handles Graph throttling (HTTP 429) with automatic backoff and retry.

    IMPORTANT EXPECTATIONS:
 - Sync makes devices CHECK IN quickly (minutes for online devices).
        The Intune portal's compliance/conflict REPORTING pipeline lags hours
        behind the check-ins. Judge progress per-device, not by portal donuts.
 - Offline devices receive the sync request at next connection.

.PARAMETER WhatIfMode
    Preview mode. Lists the devices that would be synced and exits without
    sending any sync requests.

.PARAMETER OperatingSystem
    Filter devices by OS. Default: Windows. Pass '' (empty) to target all OSes.

.PARAMETER DeviceNameFilter
    Optional wildcard filter on device name, applied client-side.
    Example: 'PBI-*' or 'LAB-*'. Default: no name filtering.

.PARAMETER MaxDevices
    Safety cap on the number of devices to sync. Default: 0 (unlimited).

.PARAMETER ThrottleDelayMs
    Fixed delay between sync calls, in milliseconds. Default 200. Raise this
    if you see repeated 429s in very large tenants.

.EXAMPLE
    .\Invoke-FleetIntuneSync.ps1 -WhatIfMode
    Preview the target list without syncing anything.

.EXAMPLE
    .\Invoke-FleetIntuneSync.ps1
    Sync every Windows device in the tenant.

.EXAMPLE
    .\Invoke-FleetIntuneSync.ps1 -DeviceNameFilter 'SALES-*' -MaxDevices 50
    Sync at most 50 devices whose names start with SALES-.

.NOTES
    Author  : (your name / org)
    Requires: Microsoft.Graph.DeviceManagement module (auto-installed if missing)
    Scope   : DeviceManagementManagedDevices.PrivilegedOperations.All
    License : MIT -  share freely.
#>

[CmdletBinding()]
param(
    [switch]$WhatIfMode,
    [string]$OperatingSystem = 'Windows',
    [string]$DeviceNameFilter = '',
    [int]$MaxDevices = 0,
    [int]$ThrottleDelayMs = 200
)

#region Configuration
# -----------------------------------------------------------------------------
# Graph scope required to issue the syncDevice action.
$RequiredScope = 'DeviceManagementManagedDevices.PrivilegedOperations.All'

# Progress reporting interval (write a status line every N devices).
$ProgressInterval = 50

# Max retries per device when throttled (HTTP 429).
$MaxRetries = 5
# -----------------------------------------------------------------------------
#endregion Configuration

#region Module + Connection
$module = 'Microsoft.Graph.DeviceManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Host "Installing $module module (CurrentUser scope)..." -ForegroundColor Yellow
    Install-Module $module -Scope CurrentUser -Force -AllowClobber
}
Import-Module $module -ErrorAction Stop

# Connect if there is no session, or the session lacks the required scope.
$context = Get-MgContext
if (-not $context -or ($context.Scopes -notcontains $RequiredScope)) {
    if ($context) {
        # Kill the cached token so the new scope is actually granted.
        # (A stale cached session is the classic cause of surprise 403s.)
        Disconnect-MgGraph | Out-Null
    }
    Write-Host "Connecting to Microsoft Graph (scope: $RequiredScope)..." -ForegroundColor Cyan
    Connect-MgGraph -Scopes $RequiredScope -NoWelcome
}
#endregion Module + Connection

#region Gather Devices
Write-Host 'Enumerating managed devices...' -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($OperatingSystem)) {
    $devices = Get-MgDeviceManagementManagedDevice -All
}
else {
    $devices = Get-MgDeviceManagementManagedDevice -All `
        -Filter "operatingSystem eq '$OperatingSystem'"
}

if ($DeviceNameFilter) {
    $devices = $devices | Where-Object DeviceName -like $DeviceNameFilter
}

# Stable ordering makes reruns and log comparison predictable.
$devices = $devices | Sort-Object DeviceName

if ($MaxDevices -gt 0 -and $devices.Count -gt $MaxDevices) {
    Write-Host "Capping target list at $MaxDevices devices (of $($devices.Count) matched)." -ForegroundColor Yellow
    $devices = $devices | Select-Object -First $MaxDevices
}

if (-not $devices -or $devices.Count -eq 0) {
    Write-Host 'No devices matched the specified filters. Nothing to do.' -ForegroundColor Yellow
    return
}

Write-Host "Matched $($devices.Count) device(s)." -ForegroundColor Green
#endregion Gather Devices

#region WhatIf Preview
if ($WhatIfMode) {
    Write-Host ''
    Write-Host '=== WHATIF MODE -  no sync requests will be sent ===' -ForegroundColor Yellow
    $devices | Select-Object DeviceName, OperatingSystem, LastSyncDateTime, UserPrincipalName |
        Format-Table -AutoSize
    Write-Host "WhatIf complete: $($devices.Count) device(s) WOULD be synced." -ForegroundColor Yellow
    return
}
#endregion WhatIf Preview

#region Sync Loop
$succeeded = 0
$failed    = 0
$failures  = [System.Collections.Generic.List[object]]::new()
$counter   = 0
$startTime = Get-Date

foreach ($d in $devices) {
    $counter++
    $attempt = 0
    $sent = $false

    while (-not $sent -and $attempt -lt $MaxRetries) {
        $attempt++
        try {
            Sync-MgDeviceManagementManagedDevice -ManagedDeviceId $d.Id -ErrorAction Stop
            $sent = $true
            $succeeded++
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match '429|TooManyRequests|throttl') {
                # Exponential backoff: 2s, 4s, 8s, 16s, 32s
                $wait = [math]::Pow(2, $attempt)
                Write-Host "  Throttled on $($d.DeviceName); backing off $wait s (attempt $attempt/$MaxRetries)..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
            }
            else {
                $failed++
                $failures.Add([pscustomobject]@{
                    DeviceName = $d.DeviceName
                    Id         = $d.Id
                    Error      = $msg
                })
                break
            }
        }
    }

    if (-not $sent -and $attempt -ge $MaxRetries) {
        $failed++
        $failures.Add([pscustomobject]@{
            DeviceName = $d.DeviceName
            Id         = $d.Id
            Error      = "Throttled after $MaxRetries retries"
        })
    }

    if ($counter % $ProgressInterval -eq 0) {
        $elapsed = (Get-Date) - $startTime
        Write-Host ("  {0} of {1} processed ({2} ok / {3} failed) -  elapsed {4:mm\:ss}" -f `
            $counter, $devices.Count, $succeeded, $failed, $elapsed)
    }

    if ($ThrottleDelayMs -gt 0) { Start-Sleep -Milliseconds $ThrottleDelayMs }
}
#endregion Sync Loop

#region Summary
$elapsed = (Get-Date) - $startTime
Write-Host ''
Write-Host '=================== SUMMARY ===================' -ForegroundColor Cyan
Write-Host ("  Sync requests sent : {0}" -f $succeeded) -ForegroundColor Green
Write-Host ("  Failures           : {0}" -f $failed)    -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
Write-Host ("  Elapsed            : {0:mm\:ss}" -f $elapsed)
Write-Host '==============================================='

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Failed devices:' -ForegroundColor Red
    $failures | Format-Table -AutoSize
}

Write-Host ''
Write-Host 'REMINDER: devices check in within minutes; portal conflict/compliance' -ForegroundColor DarkGray
Write-Host 'reporting lags HOURS behind. Verify per-device, not by the dashboards.' -ForegroundColor DarkGray
#endregion Summary
