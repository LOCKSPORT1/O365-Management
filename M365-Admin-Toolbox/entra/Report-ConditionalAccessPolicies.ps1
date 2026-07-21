<#
.SYNOPSIS
    Exports an inventory of Microsoft Entra Conditional Access policies to CSV.

.DESCRIPTION
    Connects to Microsoft Graph for the specified tenant and retrieves all
    Conditional Access policies, writing a summary (name, state, created/modified
    dates) to a CSV report. Part of the M365 Admin Toolbox reporting scripts.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. 'Tenant-Example-NA').

.PARAMETER OutputCsv
    Path to the CSV file that will be created/overwritten with the report.

.EXAMPLE
    .\Report-ConditionalAccessPolicies.ps1 -TenantName 'Tenant-Example-NA'

.EXAMPLE
    .\Report-ConditionalAccessPolicies.ps1 -TenantName 'Tenant-Example-NA' -OutputCsv 'C:\Reports\CA-Policies.csv'
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$OutputCsv = '.\reports\ConditionalAccessPolicies.csv'
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
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectGraph

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

Invoke-ToolboxSafely -TenantName $TenantName -Operation 'Report-ConditionalAccessPolicies' -Rethrow -ScriptBlock {
    $policies = Invoke-WithRetry -TenantName $TenantName -Operation 'Get-MgIdentityConditionalAccessPolicy' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
        Get-MgIdentityConditionalAccessPolicy -All
    }
    $rows = foreach ($p in $policies) {
        [pscustomobject]@{
            TenantName = $TenantName
            Id = $p.Id
            DisplayName = $p.DisplayName
            State = $p.State
            CreatedDateTime = $p.CreatedDateTime
            ModifiedDateTime = $p.ModifiedDateTime
        }
    }
    $rows | Export-Csv -NoTypeInformation -Path $OutputCsv
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Conditional Access policy report exported to $OutputCsv"
}
