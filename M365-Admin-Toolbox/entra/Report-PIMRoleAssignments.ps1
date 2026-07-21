<#
.SYNOPSIS
    Exports Microsoft Entra PIM (Privileged Identity Management) role assignments and eligibilities to CSV.

.DESCRIPTION
    Connects to Microsoft Graph for the specified tenant and reports on both
    active PIM role assignment schedule instances and eligible role schedule
    instances for directory roles, resolving each to a friendly role name via
    the role definition. Part of the M365 Admin Toolbox reporting scripts.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. 'Tenant-Example-NA').

.PARAMETER OutputCsv
    Path to the CSV file that will be created/overwritten with the report.

.EXAMPLE
    .\Report-PIMRoleAssignments.ps1 -TenantName 'Tenant-Example-NA'

.EXAMPLE
    .\Report-PIMRoleAssignments.ps1 -TenantName 'Tenant-Example-NA' -OutputCsv 'C:\Reports\PIM-Roles.csv'
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$OutputCsv = '.\reports\PIMRoleAssignments.csv'
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Number of retry attempts for throttle-safe Graph calls
$MaxRetryAttempts = 5
# Base delay (seconds) between retry attempts (doubles each attempt, capped at 60s)
$RetryBaseDelaySeconds = 5
# Graph delegated scopes required to read PIM role assignment/eligibility data
$RequiredGraphScopes = @('RoleManagement.Read.Directory','Directory.Read.All')

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectGraph -GraphScopes $RequiredGraphScopes

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

Invoke-ToolboxSafely -TenantName $TenantName -Operation 'Report-PIMRoleAssignments' -Rethrow -ScriptBlock {
    # NOTE: Get-MgDirectoryRole only returns roles that have been activated at least once
    # in the tenant. Role definitions (including never-activated roles) come from
    # Get-MgRoleManagementDirectoryRoleDefinition, which is what PIM assignments reference.
    $roleDefinitions = Invoke-WithRetry -TenantName $TenantName -Operation 'Get-MgRoleManagementDirectoryRoleDefinition' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
        Get-MgRoleManagementDirectoryRoleDefinition -All
    }

    # Active (currently in-effect) PIM role assignments
    $activeAssignments = Invoke-WithRetry -TenantName $TenantName -Operation 'Get-MgRoleManagementDirectoryRoleAssignmentScheduleInstance' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
        Get-MgRoleManagementDirectoryRoleAssignmentScheduleInstance -All
    }

    # Eligible (not yet activated) PIM role assignments
    $eligibleAssignments = Invoke-WithRetry -TenantName $TenantName -Operation 'Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
        Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance -All
    }

    $rows = foreach ($a in $activeAssignments) {
        $role = $roleDefinitions | Where-Object { $_.Id -eq $a.RoleDefinitionId }
        [pscustomobject]@{
            TenantName = $TenantName
            AssignmentType = 'Active'
            AssignmentId = $a.Id
            PrincipalId = $a.PrincipalId
            DirectoryScopeId = $a.DirectoryScopeId
            AppScopeId = $a.AppScopeId
            RoleDefinitionId = $a.RoleDefinitionId
            RoleName = if ($role) { $role.DisplayName } else { '' }
            StartDateTime = $a.StartDateTime
            EndDateTime = $a.EndDateTime
        }
    }
    $rows += foreach ($a in $eligibleAssignments) {
        $role = $roleDefinitions | Where-Object { $_.Id -eq $a.RoleDefinitionId }
        [pscustomobject]@{
            TenantName = $TenantName
            AssignmentType = 'Eligible'
            AssignmentId = $a.Id
            PrincipalId = $a.PrincipalId
            DirectoryScopeId = $a.DirectoryScopeId
            AppScopeId = $a.AppScopeId
            RoleDefinitionId = $a.RoleDefinitionId
            RoleName = if ($role) { $role.DisplayName } else { '' }
            StartDateTime = $a.StartDateTime
            EndDateTime = $a.EndDateTime
        }
    }

    $rows | Export-Csv -NoTypeInformation -Path $OutputCsv
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "PIM role assignment report exported to $OutputCsv"
}
