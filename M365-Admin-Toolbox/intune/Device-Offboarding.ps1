<#
.SYNOPSIS
    Offboards a user's Intune-managed and Entra-registered devices.

.DESCRIPTION
    Connects to Microsoft Graph for the specified tenant and, for the given user,
    optionally retires or wipes their Intune managed devices and/or disables their
    Entra ID registered device objects. This is a destructive operation against
    end-user devices (retire removes company data/management, wipe performs a full
    or protected wipe) — review the -WhatIf output before running for real, and only
    enable the switches you actually intend to run. Risky Graph calls are wrapped
    with retry logic and error handling so throttling/transient failures surface
    clearly instead of failing silently partway through.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. 'Tenant-Example-NA').

.PARAMETER UserPrincipalName
    UPN of the user being offboarded, e.g. jdoe@contoso.com.

.PARAMETER RetireDevices
    Retire all Intune managed devices owned by the user (removes company data and
    management, leaves personal data on BYOD devices).

.PARAMETER WipeDevices
    Wipe all Intune managed devices owned by the user (factory reset). Does not
    preserve enrollment or user data by default (see the KeepEnrollmentData /
    KeepUserData values in the CONFIGURATION block). Only combine this with
    -RetireDevices if you intend to run both actions in the same pass.

.PARAMETER DisableEntraDevices
    Disable (AccountEnabled = $false) all Entra ID device objects registered to the
    user, in addition to any Intune actions.

.EXAMPLE
    .\Device-Offboarding.ps1 -TenantName 'Tenant-Example-NA' -UserPrincipalName 'jdoe@contoso.com' -WhatIf

.EXAMPLE
    .\Device-Offboarding.ps1 -TenantName 'Tenant-Example-NA' -UserPrincipalName 'jdoe@contoso.com' -RetireDevices -DisableEntraDevices
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$TenantName,
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [switch]$RetireDevices,
    [switch]$WipeDevices,
    [switch]$DisableEntraDevices
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Number of retry attempts for throttle-safe Graph calls
$MaxRetryAttempts = 5
# Base delay (seconds) between retry attempts (doubles each attempt, capped at 60s)
$RetryBaseDelaySeconds = 5
# Wipe options passed to Clear-MgDeviceManagementManagedDevice
# NOTE: -UseProtectedWipe is not a real parameter of Clear-MgDeviceManagementManagedDevice
# (v1.0 SDK only supports KeepEnrollmentData / KeepUserData / MacOSUnlockCode / PersistEsimDataPlan).
$WipeKeepEnrollmentData = $false
$WipeKeepUserData = $false

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectGraph -ConnectIntune

$user = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'"
if (-not $user) { throw "User not found: $UserPrincipalName" }

# Per-user managed-device action cmdlets (Get-MgUserManagedDevice / Invoke-MgUserManagedDeviceRetire /
# Invoke-MgUserManagedDeviceWipe) do not exist in the Microsoft Graph PowerShell SDK. The supported
# approach is to enumerate tenant-wide managed devices and filter by UserId, then act on each device
# via the deviceManagement/managedDevices action cmdlets (which take a ManagedDeviceId).
$managed = Get-MgDeviceManagementManagedDevice -All | Where-Object { $_.UserId -eq $user.Id }

foreach ($device in $managed) {
    if ($RetireDevices) {
        if ($PSCmdlet.ShouldProcess("$($device.DeviceName) ($($device.Id))", 'Retire')) {
            Invoke-ToolboxSafely -TenantName $TenantName -Operation "Retire device $($device.DeviceName)/$($device.Id)" -ScriptBlock {
                Invoke-WithRetry -TenantName $TenantName -Operation 'Invoke-MgRetireDeviceManagementManagedDevice' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
                    Invoke-MgRetireDeviceManagementManagedDevice -ManagedDeviceId $device.Id
                }
            }
        }
    }
    if ($WipeDevices) {
        if ($PSCmdlet.ShouldProcess("$($device.DeviceName) ($($device.Id))", 'Wipe')) {
            Invoke-ToolboxSafely -TenantName $TenantName -Operation "Wipe device $($device.DeviceName)/$($device.Id)" -ScriptBlock {
                Invoke-WithRetry -TenantName $TenantName -Operation 'Clear-MgDeviceManagementManagedDevice' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
                    Clear-MgDeviceManagementManagedDevice -ManagedDeviceId $device.Id -KeepEnrollmentData:$WipeKeepEnrollmentData -KeepUserData:$WipeKeepUserData
                }
            }
        }
    }
}

if ($DisableEntraDevices) {
    $devices = Get-MgUserRegisteredDevice -UserId $user.Id -All
    foreach ($device in $devices) {
        if ($device.Id -and $PSCmdlet.ShouldProcess("$($device.Id)", 'Disable Entra device')) {
            Invoke-ToolboxSafely -TenantName $TenantName -Operation "Disable Entra device $($device.Id)" -ScriptBlock {
                Invoke-WithRetry -TenantName $TenantName -Operation 'Update-MgDevice' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
                    Update-MgDevice -DeviceId $device.Id -AccountEnabled:$false
                }
            }
        }
    }
}

Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message 'Device offboarding workflow completed.'
