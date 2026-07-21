<#
.SYNOPSIS
    Handles the device side of offboarding: retire or wipe an Intune
    managed device, remove its Autopilot registration, and delete the
    stale Entra device object.

.DESCRIPTION
    -Action Retire   : removes company data/MDM management, leaves personal
                        data intact. Use for BYOD or when the device is
                        being reassigned and you don't need a full wipe.
    -Action Wipe     : full factory reset. Use for company-owned devices
                        being decommissioned or repurposed to a new user
                        from scratch.
    -Action Delete   : just removes the stale Intune/Entra device record
                        (e.g. after a device already checked itself out,
                        or a duplicate/ghost record from a re-image).

.NOTES
    Wipe and Retire are DESTRUCTIVE and cannot be undone once the device
    checks in and executes the command. Confirm the device identity twice.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$DeviceName,
    [ValidateSet("Retire","Wipe","Delete")]
    [Parameter(Mandatory)][string]$Action,
    [switch]$RemoveAutopilotRegistration,
    [switch]$Confirmed,   # explicit safety flag - script refuses to run destructive actions without it

    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

#region Configuration
# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Actions that are considered destructive and therefore require both
# -WhatIf/-Confirm (ShouldProcess) AND the explicit -Confirmed switch.
$Config = @{
    DestructiveActions = @("Retire","Wipe")
}
#endregion

if ($Action -in $Config.DestructiveActions -and -not $Confirmed) {
    Write-Error "This is a destructive action ('$Action'). Re-run with -Confirmed to proceed. Aborting without changes."
    return
}

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

try {
    $device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$DeviceName'"
}
catch {
    Write-Error "Failed to query Intune for device '$DeviceName': $_"
    return
}

if (-not $device) {
    Write-Error "Device '$DeviceName' not found in Intune. Check the exact device name via Get-IntuneDeviceInventory.ps1."
    return
}

if (@($device).Count -gt 1) {
    Write-Error "Multiple devices matched name '$DeviceName' - refusing to proceed against an ambiguous target. Use Get-IntuneDeviceInventory.ps1 to identify the correct IntuneDeviceId and adjust the filter."
    return
}

Write-Host "Target device: $($device.DeviceName) | User: $($device.UserPrincipalName) | Serial: $($device.SerialNumber)" -ForegroundColor Cyan

switch ($Action) {
    "Retire" {
        if ($PSCmdlet.ShouldProcess($device.DeviceName, "Retire (remove MDM management)")) {
            try {
                Invoke-MgRetireDeviceManagementManagedDevice -ManagedDeviceId $device.Id
                Write-Host "[OK] Retire command sent. Device will de-enroll on next check-in." -ForegroundColor Green
            }
            catch {
                Write-Error "Retire command failed for '$($device.DeviceName)': $_"
            }
        }
    }
    "Wipe" {
        if ($PSCmdlet.ShouldProcess($device.DeviceName, "Full wipe / factory reset")) {
            try {
                # NOTE: the Graph SDK cmdlet for wipe is Clear-MgDeviceManagementManagedDevice
                # (there is no Invoke-MgWipeDeviceManagementManagedDevice cmdlet).
                Clear-MgDeviceManagementManagedDevice -ManagedDeviceId $device.Id -KeepEnrollmentData:$false -KeepUserData:$false
                Write-Host "[OK] Wipe command sent. Device will factory reset on next check-in." -ForegroundColor Green
            }
            catch {
                Write-Error "Wipe command failed for '$($device.DeviceName)': $_"
            }
        }
    }
    "Delete" {
        if ($PSCmdlet.ShouldProcess($device.DeviceName, "Delete stale Intune device record")) {
            try {
                Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $device.Id
                Write-Host "[OK] Intune device record deleted." -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to delete Intune device record for '$($device.DeviceName)': $_"
            }
        }
    }
}

if ($RemoveAutopilotRegistration -and $device.SerialNumber) {
    try {
        $apDevice = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "serialNumber eq '$($device.SerialNumber)'"
    }
    catch {
        Write-Error "Failed to look up Autopilot registration for serial '$($device.SerialNumber)': $_"
        $apDevice = $null
    }

    if ($apDevice) {
        if ($PSCmdlet.ShouldProcess($device.SerialNumber, "Remove Autopilot registration")) {
            try {
                Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $apDevice.Id
                Write-Host "[OK] Autopilot registration removed." -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to remove Autopilot registration for '$($device.SerialNumber)': $_"
            }
        }
    }
    else {
        Write-Host "[INFO] No Autopilot registration found for this serial number." -ForegroundColor Yellow
    }
}

# Also clean up the corresponding Entra device object if it's now stale (Delete action only)
if ($Action -eq "Delete") {
    try {
        $entraDevice = Get-MgDevice -Filter "deviceId eq '$($device.AzureAdDeviceId)'"
    }
    catch {
        Write-Error "Failed to look up Entra device object for AzureAdDeviceId '$($device.AzureAdDeviceId)': $_"
        $entraDevice = $null
    }

    if ($entraDevice) {
        if ($PSCmdlet.ShouldProcess($entraDevice.DisplayName, "Delete stale Entra device object")) {
            try {
                Remove-MgDevice -DeviceId $entraDevice.Id
                Write-Host "[OK] Entra device object deleted." -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to delete Entra device object '$($entraDevice.DisplayName)': $_"
            }
        }
    }
}
