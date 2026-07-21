<#
.SYNOPSIS
    Adds, removes, or lists a Microsoft Entra ID user's group memberships.

.DESCRIPTION
    Connects to Microsoft Graph for the specified tenant and performs a single
    group-membership operation (add, remove, or list) against one user. Intended
    for ad-hoc or scripted group membership changes as part of the M365 Admin
    Toolbox. Risky Graph calls are wrapped with retry logic and error handling
    so throttling and transient failures do not silently fail the operation.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. 'Tenant-Example-NA').

.PARAMETER Action
    The operation to perform: AddUserToGroup, RemoveUserFromGroup, or ListUserGroups.

.PARAMETER UserPrincipalName
    UPN of the user to operate on, e.g. jdoe@yourtenant.onmicrosoft.com.

.PARAMETER GroupId
    Object ID (GUID) of the target group. Required for AddUserToGroup and
    RemoveUserFromGroup; ignored for ListUserGroups.

.EXAMPLE
    .\Entra-UserGroupMgmt.ps1 -TenantName 'Tenant-Example-NA' -Action AddUserToGroup -UserPrincipalName 'jdoe@contoso.com' -GroupId '11111111-2222-3333-4444-555555555555'

.EXAMPLE
    .\Entra-UserGroupMgmt.ps1 -TenantName 'Tenant-Example-NA' -Action ListUserGroups -UserPrincipalName 'jdoe@contoso.com'
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [Parameter(Mandatory)][ValidateSet('AddUserToGroup','RemoveUserFromGroup','ListUserGroups')][string]$Action,
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string]$GroupId
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

$user = Invoke-WithRetry -TenantName $TenantName -Operation 'Get-MgUser' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
    Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'"
}
if (-not $user) { throw "User not found: $UserPrincipalName" }

Invoke-ToolboxSafely -TenantName $TenantName -Operation "$Action for $UserPrincipalName" -Rethrow -ScriptBlock {
    switch ($Action) {
        'AddUserToGroup' {
            if (-not $GroupId) { throw 'GroupId is required.' }
            Invoke-WithRetry -TenantName $TenantName -Operation 'New-MgGroupMember' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
                New-MgGroupMember -GroupId $GroupId -DirectoryObjectId $user.Id
            }
        }
        'RemoveUserFromGroup' {
            if (-not $GroupId) { throw 'GroupId is required.' }
            Invoke-WithRetry -TenantName $TenantName -Operation 'Remove-MgGroupMemberByRef' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
                Remove-MgGroupMemberByRef -GroupId $GroupId -DirectoryObjectId $user.Id
            }
        }
        'ListUserGroups' {
            Invoke-WithRetry -TenantName $TenantName -Operation 'Get-MgUserMemberOf' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
                Get-MgUserMemberOf -UserId $user.Id -All
            }
        }
    }
}
