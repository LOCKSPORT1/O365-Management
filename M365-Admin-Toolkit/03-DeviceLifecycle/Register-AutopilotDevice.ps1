<#
.SYNOPSIS
    Registers one or more devices for Windows Autopilot from a CSV of
    hardware hashes, and assigns them to a deployment profile group.

.DESCRIPTION
    Expects a CSV with columns: SerialNumber, HardwareHash, GroupTag
    (the standard format produced by Get-WindowsAutoPilotInfo.ps1 run on
    the device itself, or exported from an OEM/vendor).

    After import, adds the device's Entra object to a specified group so
    it picks up the right Autopilot deployment profile via dynamic/assigned
    group membership - this is how you target profiles per device type
    (e.g. laptops vs conference room PCs vs kiosks).

.NOTES
    You still need to run Get-WindowsAutoPilotInfo.ps1 (Microsoft's script,
    not part of this toolkit) on each source device first to generate the
    hash CSV, unless your OEM/reseller provides hashes directly.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string]$AssignToGroupName,
    [switch]$WaitForImport,

    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

#region Configuration
# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# How often (seconds) to poll import status when -WaitForImport is used.
# Default GroupTag applied when a CSV row doesn't supply one (blank = none).
# Number of times to retry a single device's import queue call on failure.
# Delay (seconds) between retry attempts for a failed import queue call.
$Config = @{
    ImportPollIntervalSeconds = 30
    ImportMaxWaitMinutes      = 15
    DefaultGroupTag           = ""
    ImportRetryCount          = 2
    ImportRetryDelaySeconds   = 5
}
#endregion

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV not found at $CsvPath"
    return
}

$rows = Import-Csv $CsvPath
Write-Host "Importing $($rows.Count) device(s) into Autopilot..." -ForegroundColor Cyan

$importedIds = @()
foreach ($row in $rows) {
    $groupTag = if ([string]::IsNullOrWhiteSpace($row.GroupTag)) { $Config.DefaultGroupTag } else { $row.GroupTag }

    # hardwareIdentifier must be submitted as Base64-encoded bytes, not a raw string -
    # Get-WindowsAutoPilotInfo.ps1 already emits the hash pre-encoded as Base64 text,
    # so we decode it to a byte array here to match what the Graph SDK expects.
    try {
        $hashBytes = [System.Convert]::FromBase64String($row.HardwareHash)
    }
    catch {
        Write-Warning "Skipping $($row.SerialNumber): HardwareHash is not valid Base64 - $_"
        continue
    }

    $body = @{
        "@odata.type"      = "#microsoft.graph.importedWindowsAutopilotDeviceIdentity"
        serialNumber       = $row.SerialNumber
        hardwareIdentifier = $hashBytes
        groupTag           = $groupTag
    }

    $attempt = 0
    $queued = $false
    do {
        $attempt++
        try {
            $result = New-MgDeviceManagementImportedWindowsAutopilotDeviceIdentity -BodyParameter $body
            $importedIds += $result.Id
            Write-Host "  Queued: $($row.SerialNumber)" -ForegroundColor Green
            $queued = $true
        }
        catch {
            if ($attempt -le $Config.ImportRetryCount) {
                Write-Warning "Attempt $attempt failed to queue $($row.SerialNumber): $_ - retrying in $($Config.ImportRetryDelaySeconds)s..."
                Start-Sleep -Seconds $Config.ImportRetryDelaySeconds
            }
            else {
                Write-Warning "Failed to queue $($row.SerialNumber) after $attempt attempt(s): $_"
            }
        }
    } while (-not $queued -and $attempt -le $Config.ImportRetryCount)
}

if ($WaitForImport -and $importedIds.Count -eq 0) {
    Write-Warning "No devices were successfully queued - skipping wait for import."
}
elseif ($WaitForImport) {
    Write-Host "Waiting for import to complete (poll every $($Config.ImportPollIntervalSeconds)s, max $($Config.ImportMaxWaitMinutes)min)..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes($Config.ImportMaxWaitMinutes)
    do {
        Start-Sleep -Seconds $Config.ImportPollIntervalSeconds
        $statuses = $importedIds | ForEach-Object { Get-MgDeviceManagementImportedWindowsAutopilotDeviceIdentity -ImportedWindowsAutopilotDeviceIdentityId $_ }
        # 'partial' covers devices that imported but had a non-fatal issue (e.g. profile
        # assignment lag) - treated as still-in-progress rather than done or failed.
        $pending = $statuses | Where-Object { $_.State.DeviceImportStatus -in @('unknown', 'pending', 'partial') }
        Write-Host "  Pending: $($pending.Count) / $($importedIds.Count)"
    } while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)

    $failed = $statuses | Where-Object { $_.State.DeviceImportStatus -eq 'error' }
    if ($failed) {
        Write-Warning "$($failed.Count) device(s) failed import - check State.DeviceErrorCode on each."
    }
}

if ($AssignToGroupName) {
    $group = Get-MgGroup -Filter "displayName eq '$AssignToGroupName'"
    if (-not $group) {
        Write-Warning "Group '$AssignToGroupName' not found - devices imported but not grouped. Add manually once Entra device objects appear."
    }
    else {
        Write-Host "Note: newly imported Autopilot devices take a few minutes to appear as Entra device objects before group assignment by serial/hash is possible. Re-run a group-add pass separately once they show up in 'Get-MgDevice'." -ForegroundColor Yellow
    }
}

Write-Host "`nDone. Devices will appear in Intune/Autopilot within a few minutes to a few hours depending on sync timing." -ForegroundColor Cyan
