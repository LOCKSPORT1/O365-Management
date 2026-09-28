<#
.SYNOPSIS
    Finds Intune devices whose primary user is a disabled (offboarded) account, and
    optionally clears the primary user so the hardware can be reassigned.

.DESCRIPTION
    Devices circulate between staff. When someone is offboarded, their Intune primary user
    assignment stays on the hardware unless it is explicitly removed - which blocks a clean
    handover to the next person and leaves a terminated account attached to a live device.

    This script enumerates every disabled user in the tenant, lists the Intune devices where
    they are still the primary user, and can clear that assignment.

    READ-ONLY BY DEFAULT. Nothing changes unless -Fix is passed.

    What clearing the primary user does and does not do:
      DOES     remove the user <-> device relationship, freeing the device for reassignment
      DOES NOT retire, wipe, unenroll, or delete anything - the device stays managed
      DOES NOT touch the user account
      REVERSIBLE - assigning a new primary user in Intune is a normal action

    Side effect worth knowing: app and policy assignments targeted at the USER (rather than
    at the device) stop applying while a device has no primary user, until a new one is set.
    For a departed employee's machine awaiting reassignment that is normally what you want.

    WHY BETA: primary user is a relationship on managedDevice, not a settable property, so it
    is cleared with DELETE on .../users/$ref. The v1.0 managedDevice type does not expose the
    users navigation property, so the beta endpoint is required. Likewise usersLoggedOn, used
    for the last-signed-in evidence, is beta-only.

.PARAMETER Fix
    Actually clear the primary user on the devices found. Without this the script only
    reports. Supports -WhatIf and -Confirm.

.PARAMETER AddNote
    Append a dated note to each device's Intune Notes field recording what was done and why,
    so the next person to look at the device has the history. Existing notes are preserved.

.PARAMETER MinDaysSinceLastSync
    Only report devices that have not checked in for at least this many days. Useful for
    separating hardware that is probably sitting in a drawer from machines still in daily
    use under a stale assignment. Default 0 (all devices).

.PARAMETER ReportPath
    Folder for the CSV report. Defaults to a Reports folder beside this script.

.EXAMPLE
    .\Repair-DevicePrimaryUser.ps1
    Report only - lists every device whose primary user is a disabled account.

.EXAMPLE
    .\Repair-DevicePrimaryUser.ps1 -Fix -AddNote -WhatIf
    Shows exactly what would be cleared, changing nothing.

.EXAMPLE
    .\Repair-DevicePrimaryUser.ps1 -Fix -AddNote
    Clears the primary user on each device found and records a note on it.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Users
    Scopes:   User.Read.All, DeviceManagementManagedDevices.ReadWrite.All
              (Read.All is enough when not using -Fix)
    Role:     Intune Administrator

    Companion to Offboard-HybridUser.ps1, which clears the primary user at
    offboarding time by default. This script is the sweep for accounts offboarded before
    that behaviour existed, or where the device stage failed.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [switch]$Fix,
    [switch]$AddNote,
    [int]$MinDaysSinceLastSync = 0,
    [string]$ReportPath = (Join-Path $PSScriptRoot 'Reports')
)

$ErrorActionPreference = 'Stop'
$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'

#region Connect
$needScopes = if ($Fix) {
    @('User.Read.All', 'DeviceManagementManagedDevices.ReadWrite.All')
} else {
    @('User.Read.All', 'DeviceManagementManagedDevices.Read.All')
}

foreach ($m in 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Users') {
    if (-not (Get-Module -Name $m)) { Import-Module $m -ErrorAction Stop }
}

$ctx = Get-MgContext
$haveAll = $ctx -and -not @($needScopes | Where-Object {
    $_ -notin $ctx.Scopes -and
    -not ($_ -eq 'DeviceManagementManagedDevices.Read.All' -and
          $ctx.Scopes -contains 'DeviceManagementManagedDevices.ReadWrite.All')
}).Count

if (-not $haveAll) {
    Write-Host "Connecting to Microsoft Graph (scopes: $($needScopes -join ', '))..." -ForegroundColor Yellow
    Connect-MgGraph -Scopes $needScopes -NoWelcome
}
Write-Host "Tenant: $((Get-MgContext).TenantId)  as  $((Get-MgContext).Account)" -ForegroundColor DarkGray
#endregion

#region Collect
Write-Host "`nFinding disabled accounts..." -ForegroundColor Cyan
$disabled = @(Get-MgUser -Filter 'accountEnabled eq false' -Property Id, DisplayName, UserPrincipalName -All)
Write-Host "  $($disabled.Count) disabled account(s)" -ForegroundColor DarkGray

Write-Host "Checking Intune devices for each..." -ForegroundColor Cyan
$findings = New-Object System.Collections.Generic.List[Object]
$queryErrors = 0
$noDevices   = 0
$i = 0

foreach ($u in $disabled) {
    $i++
    if ($i % 25 -eq 0) { Write-Host "  ...$i of $($disabled.Count)" -ForegroundColor DarkGray }

    try {
        # /users/{id}/managedDevices, NOT /deviceManagement/managedDevices with a userId
        # filter - Microsoft's Intune backend rejects that filter with "Unsupported parameter
        # found in query" (api-version 2025-07-09 onward, seen 2026-08-20).
        $resp = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/users/$($u.Id)/managedDevices" -ErrorAction Stop
    }
    catch {
        # A 404 here means the user has NO managed devices - Graph returns NotFound for this
        # navigation property rather than an empty collection. That is the normal case for
        # most disabled accounts (service accounts, shared mailboxes, staff who never had a
        # managed device) and is NOT an error. Only non-404 failures leave devices unreviewed.
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 404 -or $_.Exception.Message -match 'NotFound') {
            $noDevices++
            continue
        }

        $queryErrors++
        Write-Warning "Could not query devices for $($u.UserPrincipalName): $($_.Exception.Message)"
        continue
    }

    foreach ($d in @($resp.value)) {
        $lastSync = $null
        if ($d.lastSyncDateTime) { $lastSync = [datetime]$d.lastSyncDateTime }
        $daysIdle = if ($lastSync) { [int]((Get-Date) - $lastSync).TotalDays } else { $null }

        if ($MinDaysSinceLastSync -gt 0 -and
            ($null -eq $daysIdle -or $daysIdle -lt $MinDaysSinceLastSync)) { continue }

        $findings.Add([PSCustomObject]@{
            User        = $u.UserPrincipalName
            UserId      = $u.Id
            Device      = $d.deviceName
            DeviceId    = $d.id
            OS          = "$($d.operatingSystem) $($d.osVersion)"
            Model       = "$($d.manufacturer) $($d.model)".Trim()
            Serial      = $d.serialNumber
            Compliance  = $d.complianceState
            LastSync    = $lastSync
            DaysIdle    = $daysIdle
            Action      = 'Reported'
            Detail      = ''
        })
    }
}

Write-Host "  $noDevices account(s) have no managed devices" -ForegroundColor DarkGray
if ($queryErrors) {
    Write-Warning "$queryErrors account(s) could not be queried - their devices are UNREVIEWED. See warnings above."
}

if ($findings.Count -eq 0) {
    Write-Host "`nNo devices found with a disabled account as primary user." -ForegroundColor Green
    return
}

Write-Host "`n$($findings.Count) device(s) still assigned to a disabled account:`n" -ForegroundColor Yellow
$findings | Sort-Object DaysIdle |
    Format-Table Device, User, Model, Serial, LastSync, DaysIdle -AutoSize
#endregion

#region Fix
if ($Fix) {
    Write-Host "`nClearing primary user assignments..." -ForegroundColor Cyan

    foreach ($f in $findings) {
        if (-not $PSCmdlet.ShouldProcess("$($f.Device) (primary user $($f.User))", 'Clear Intune primary user')) {
            $f.Action = 'Skipped'
            $f.Detail = 'WhatIf / declined at confirmation prompt'
            continue
        }

        try {
            $refUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$($f.DeviceId)')/users/`$ref"
            Invoke-MgGraphRequest -Method DELETE -Uri $refUri -ErrorAction Stop | Out-Null
            $f.Action = 'Cleared'
            $f.Detail = "Primary user removed; device remains enrolled and managed"
            Write-Host "  cleared: $($f.Device)  (was $($f.User))" -ForegroundColor Green
        }
        catch {
            $f.Action = 'Failed'
            $f.Detail = $_.Exception.Message
            Write-Host "  FAILED : $($f.Device) - $($_.Exception.Message)" -ForegroundColor Red
            continue
        }

        if ($AddNote) {
            try {
                $stamp = Get-Date -Format 'yyyy-MM-dd'
                $line  = "[PRIMARY USER CLEARED $stamp] $($f.User) was offboarded; primary user assignment removed by $($env:USERNAME) so this device can be reassigned. Device was NOT retired or wiped."

                # Read current notes first so existing history is preserved rather than
                # overwritten - PATCH on notes replaces the whole field.
                $cur      = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($f.DeviceId)" -ErrorAction Stop
                $existing = $cur.notes
                $newNotes = if ([string]::IsNullOrWhiteSpace($existing)) { $line }
                            else { ($existing.TrimEnd() + "`r`n" + $line) }

                Invoke-MgGraphRequest -Method PATCH `
                    -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($f.DeviceId)" `
                    -Body (@{ notes = $newNotes } | ConvertTo-Json) -ErrorAction Stop | Out-Null

                $f.Detail += '; note added'
            }
            catch {
                $f.Detail += "; note FAILED: $($_.Exception.Message)"
            }
        }
    }
}
else {
    Write-Host "`nReport only - nothing was changed." -ForegroundColor DarkYellow
    Write-Host "Re-run with -Fix to clear these primary user assignments (add -WhatIf first to preview)." -ForegroundColor DarkYellow
}
#endregion

#region Report
try {
    if (-not (Test-Path -LiteralPath $ReportPath)) {
        New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
    }
    $csv = Join-Path $ReportPath "DevicePrimaryUser_$runStamp.csv"
    $findings | Export-Csv -LiteralPath $csv -NoTypeInformation
    Write-Host "`nReport: $csv" -ForegroundColor Cyan
}
catch {
    Write-Warning "Could not write report to '$ReportPath': $($_.Exception.Message)"
}

$failed = @($findings | Where-Object Action -eq 'Failed')
if ($failed.Count) {
    Write-Warning "$($failed.Count) device(s) could not be cleared - clear them in Intune manually (Devices > <name> > Properties > Primary user)."
}
#endregion

