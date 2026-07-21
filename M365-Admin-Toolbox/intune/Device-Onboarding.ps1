<#
.SYNOPSIS
    Looks up a user's Intune managed device(s), optionally assigns a device category,
    and optionally triggers a policy sync.

.DESCRIPTION
    Connects to Microsoft Graph for the specified tenant and finds the Intune managed
    devices belonging to the given user (optionally narrowed to a single device by
    name). If -DeviceCategoryDisplayName is supplied, the matching Intune device
    category is resolved and applied to each device found. If -SyncDevice is supplied,
    a Graph sync command is sent to each device so it checks in immediately instead
    of waiting for its normal Intune check-in interval.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. 'Tenant-Example-NA').

.PARAMETER UserPrincipalName
    UPN of the device owner, e.g. jdoe@contoso.com.

.PARAMETER ManagedDeviceName
    Optional. Restrict the operation to the single Intune managed device with this
    DeviceName. If omitted, all of the user's managed devices are processed.

.PARAMETER DeviceCategoryDisplayName
    Optional. Display name of an existing Intune device category (see
    config\tenants.json Cloud.DefaultDeviceCategories for tenant defaults) to assign
    to the matched device(s).

.PARAMETER SyncDevice
    If set, sends an immediate Intune sync command to each matched device.

.EXAMPLE
    .\Device-Onboarding.ps1 -TenantName 'Tenant-Example-NA' -UserPrincipalName 'jdoe@contoso.com' -SyncDevice

.EXAMPLE
    .\Device-Onboarding.ps1 -TenantName 'Tenant-Example-NA' -UserPrincipalName 'jdoe@contoso.com' -ManagedDeviceName 'DESKTOP-ABC123' -DeviceCategoryDisplayName 'Corporate Laptops'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$TenantName,
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string]$ManagedDeviceName,
    [string]$DeviceCategoryDisplayName,
    [switch]$SyncDevice
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Number of retry attempts for throttle-safe Graph calls
$MaxRetryAttempts = 5
# Base delay (seconds) between retry attempts (doubles each attempt, capped at 60s)
$RetryBaseDelaySeconds = 5

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectGraph -ConnectIntune

$user = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'"
if (-not $user) { throw "User not found: $UserPrincipalName" }

# Get-MgUserManagedDevice does not exist in the Microsoft Graph PowerShell SDK. Managed devices
# are enumerated tenant-wide and filtered by UserId, matching the approach used in
# Device-Offboarding.ps1 and Cleanup-StaleDevices.ps1.
$devices = Get-MgDeviceManagementManagedDevice -All | Where-Object { $_.UserId -eq $user.Id }
if ($ManagedDeviceName) { $devices = $devices | Where-Object { $_.DeviceName -eq $ManagedDeviceName } }

if (-not $devices) {
    Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "No managed devices found for $UserPrincipalName (ManagedDeviceName filter: '$ManagedDeviceName')."
}

$categoryId = $null
if ($DeviceCategoryDisplayName) {
    # Get-MgDeviceManagementDeviceCategory (not the similarly-named
    # Get-MgDeviceManagementManagedDeviceCategory, which looks up the category already
    # assigned to a single device) lists the tenant's available device categories.
    $category = Get-MgDeviceManagementDeviceCategory -All | Where-Object { $_.DisplayName -eq $DeviceCategoryDisplayName }
    if (-not $category) { throw "Device category not found: $DeviceCategoryDisplayName" }
    $categoryId = $category.Id
}

foreach ($device in $devices) {
    Write-ToolboxLog -TenantName $TenantName -Message "Found device $($device.DeviceName) for $UserPrincipalName"

    if ($DeviceCategoryDisplayName) {
        if ($PSCmdlet.ShouldProcess("$($device.DeviceName) ($($device.Id))", "Set device category to '$DeviceCategoryDisplayName'")) {
            Invoke-ToolboxSafely -TenantName $TenantName -Operation "Set category on $($device.DeviceName)/$($device.Id)" -ScriptBlock {
                Invoke-WithRetry -TenantName $TenantName -Operation 'Set-MgDeviceManagementManagedDeviceCategoryByRef' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
                    Set-MgDeviceManagementManagedDeviceCategoryByRef -ManagedDeviceId $device.Id -OdataId "https://graph.microsoft.com/v1.0/deviceManagement/deviceCategories('$categoryId')"
                }
            }
        }
    }

    if ($SyncDevice) {
        if ($PSCmdlet.ShouldProcess("$($device.DeviceName) ($($device.Id))", 'Sync device')) {
            Invoke-ToolboxSafely -TenantName $TenantName -Operation "Sync $($device.DeviceName)/$($device.Id)" -ScriptBlock {
                Invoke-WithRetry -TenantName $TenantName -Operation 'Sync-MgDeviceManagementManagedDevice' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
                    Sync-MgDeviceManagementManagedDevice -ManagedDeviceId $device.Id
                }
            }
        }
    }
}

Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message 'Device onboarding workflow completed.'
