<#
.SYNOPSIS
    Retires or deletes Intune-managed devices that have not synced within a configurable
    number of days.

.DESCRIPTION
    Connects to Microsoft Graph for the specified tenant and finds Intune managed devices
    whose LastSyncDateTime is older than the configured inactivity threshold. Before taking
    any action it generates a pre-cleanup CSV snapshot of the candidates (via
    Report-StaleDevices.ps1) so the run can be reviewed or rolled back to a known list.
    This script is destructive: it can retire (Retire) or permanently remove the Intune
    device record (Delete) for every matching device. Supports -WhatIf to preview the
    candidates without taking action, and uses ShouldProcess so -Confirm/-WhatIf behave
    the standard PowerShell way.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. 'Tenant-Example-NA').

.PARAMETER InactiveDays
    Number of days since last Intune sync before a device is considered stale.
    Defaults to the value in the CONFIGURATION block below.

.PARAMETER Action
    What to do with each stale device candidate: 'Retire' (default, sends a retire command
    via Graph) or 'Delete' (removes the Intune managed device record outright).

.EXAMPLE
    .\Cleanup-StaleDevices.ps1 -TenantName 'Tenant-Example-NA' -WhatIf

.EXAMPLE
    .\Cleanup-StaleDevices.ps1 -TenantName 'Tenant-Example-NA' -InactiveDays 120 -Action Retire
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$TenantName,
    [int]$InactiveDays,
    [ValidateSet('Retire','Delete')][string]$Action = 'Retire'
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Number of days since last Intune sync before a device is considered stale
$DefaultInactiveDays = 90
# Number of retry attempts for throttle-safe Graph calls
$MaxRetryAttempts = 5
# Base delay (seconds) between retry attempts (doubles each attempt, capped at 60s)
$RetryBaseDelaySeconds = 5

if (-not $PSBoundParameters.ContainsKey('InactiveDays')) { $InactiveDays = $DefaultInactiveDays }

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')

# Produce a pre-cleanup snapshot of stale device candidates before doing anything destructive.
$preCleanupCsv = Join-Path $PSScriptRoot "..\reports\StaleDevices_PreCleanup_$((Get-Date).ToString('yyyyMMddHHmmss')).csv"
. (Join-Path $PSScriptRoot 'Report-StaleDevices.ps1') -TenantName $TenantName -InactiveDays $InactiveDays -OutputCsv $preCleanupCsv

. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectGraph -ConnectIntune

$cutoff = (Get-Date).ToUniversalTime().AddDays(-$InactiveDays)
$devices = Get-MgDeviceManagementManagedDevice -All | Where-Object { $_.LastSyncDateTime -and ([datetime]$_.LastSyncDateTime).ToUniversalTime() -lt $cutoff }

Write-ToolboxLog -TenantName $TenantName -Message "Found $($devices.Count) stale device candidate(s) (InactiveDays=$InactiveDays). Pre-cleanup snapshot: $preCleanupCsv"

foreach ($d in $devices) {
    Write-ToolboxLog -TenantName $TenantName -Message "Stale device candidate: $($d.DeviceName) / $($d.Id) / LastSync=$($d.LastSyncDateTime)"

    if (-not $PSCmdlet.ShouldProcess("$($d.DeviceName) ($($d.Id))", $Action)) { continue }

    Invoke-ToolboxSafely -TenantName $TenantName -Operation "$Action stale device $($d.DeviceName)/$($d.Id)" -ScriptBlock {
        Invoke-WithRetry -TenantName $TenantName -Operation "$Action-ManagedDevice" -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
            if ($Action -eq 'Retire') {
                Invoke-MgRetireDeviceManagementManagedDevice -ManagedDeviceId $d.Id
            } elseif ($Action -eq 'Delete') {
                Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $d.Id
            }
        }
    }
}

Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Stale device cleanup workflow completed. Action=$Action"
