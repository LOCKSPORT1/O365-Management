<#
.SYNOPSIS
    Exports a Microsoft 365 license (subscribed SKU) inventory to CSV.

.DESCRIPTION
    Connects to Microsoft Graph for the specified tenant and reports on
    subscribed SKUs (consumed/available/prepaid units), optionally including
    service plan detail per SKU and per-user license assignment rows. Part of
    the M365 Admin Toolbox reporting scripts.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. 'Tenant-Example-NA').

.PARAMETER OutputCsv
    Path to the CSV file that will be created/overwritten with the report.

.PARAMETER IncludeServicePlans
    If specified, includes a semicolon-delimited list of service plan names
    for each SKU summary row.

.PARAMETER IncludeUserAssignments
    If specified, also enumerates all users and adds one row per assigned
    license (RecordType = 'UserAssignment').

.EXAMPLE
    .\Report-LicenseInventory.ps1 -TenantName 'Tenant-Example-NA'

.EXAMPLE
    .\Report-LicenseInventory.ps1 -TenantName 'Tenant-Example-NA' -IncludeServicePlans -IncludeUserAssignments -OutputCsv 'C:\Reports\Licenses.csv'
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$OutputCsv = '.\reports\LicenseInventory.csv',
    [switch]$IncludeServicePlans,
    [switch]$IncludeUserAssignments
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Number of retry attempts for throttle-safe Graph calls
$MaxRetryAttempts = 5
# Base delay (seconds) between retry attempts (doubles each attempt, capped at 60s)
$RetryBaseDelaySeconds = 5
# Properties requested when enumerating users for license assignment rows
$UserAssignmentProperties = @('UserPrincipalName','AssignedLicenses')

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectGraph

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

Invoke-ToolboxSafely -TenantName $TenantName -Operation 'Report-LicenseInventory' -Rethrow -ScriptBlock {
    $skus = Invoke-WithRetry -TenantName $TenantName -Operation 'Get-MgSubscribedSku' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
        Get-MgSubscribedSku
    }
    $summary = foreach ($sku in $skus) {
        [pscustomobject]@{
            TenantName = $TenantName
            SkuPartNumber = $sku.SkuPartNumber
            SkuId = $sku.SkuId
            ConsumedUnits = $sku.ConsumedUnits
            PrepaidEnabled = $sku.PrepaidUnits.Enabled
            PrepaidSuspended = $sku.PrepaidUnits.Suspended
            PrepaidWarning = $sku.PrepaidUnits.Warning
            AvailableUnits = ($sku.PrepaidUnits.Enabled - $sku.ConsumedUnits)
            ServicePlans = if ($IncludeServicePlans) { ($sku.ServicePlans.ServicePlanName -join ';') } else { '' }
            RecordType = 'SkuSummary'
            UserPrincipalName = ''
        }
    }

    $userRows = @()
    if ($IncludeUserAssignments) {
        $users = Invoke-WithRetry -TenantName $TenantName -Operation 'Get-MgUser' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
            Get-MgUser -All -Property $UserAssignmentProperties
        }
        foreach ($user in $users) {
            foreach ($license in $user.AssignedLicenses) {
                $match = $skus | Where-Object { $_.SkuId -eq $license.SkuId }
                $userRows += [pscustomobject]@{
                    TenantName = $TenantName
                    SkuPartNumber = if ($match) { $match.SkuPartNumber } else { '' }
                    SkuId = $license.SkuId
                    ConsumedUnits = ''
                    PrepaidEnabled = ''
                    PrepaidSuspended = ''
                    PrepaidWarning = ''
                    AvailableUnits = ''
                    ServicePlans = ''
                    RecordType = 'UserAssignment'
                    UserPrincipalName = $user.UserPrincipalName
                }
            }
        }
    }

    @($summary + $userRows) | Export-Csv -NoTypeInformation -Path $OutputCsv
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "License inventory exported to $OutputCsv"
}
