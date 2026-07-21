<#
.SYNOPSIS
    Disables a hybrid (on-prem synced) Active Directory user account.

.DESCRIPTION
    Connects to the tenant's configured on-prem domain controller / management host
    and disables the specified AD account. Optionally removes the user from all
    non-default groups and/or moves the account to the tenant's configured
    "disabled users" OU. Designed for hybrid tenants where the source of authority
    for the identity is on-prem AD (synced to Entra ID via AAD/Entra Connect).

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json. Used to resolve the
    on-prem remote host and OU paths from the tenant's OnPrem configuration block.

.PARAMETER SamAccountName
    The sAMAccountName of the on-prem AD user to disable.

.PARAMETER MoveToDisabledOU
    If specified, moves the user object to the tenant's configured
    OnPrem.OUPathDisabledUsers after disabling it.

.PARAMETER RemoveFromAllNonDefaultGroups
    If specified, removes the user from every group returned by their MemberOf
    property (best-effort; failures for individual groups are logged and do not
    stop the overall operation).

.EXAMPLE
    .\Disable-HybridADUser.ps1 -TenantName 'Contoso' -SamAccountName 'jdoe' -MoveToDisabledOU -RemoveFromAllNonDefaultGroups

    Disables jdoe's on-prem AD account, strips group memberships, and moves the
    account into the tenant's disabled-users OU.
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [Parameter(Mandatory)][string]$SamAccountName,
    [switch]$MoveToDisabledOU,
    [switch]$RemoveFromAllNonDefaultGroups
)

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')

$tenant = Get-TenantConfig -TenantName $TenantName

Invoke-ToolboxSafely -TenantName $TenantName -Operation "Disable hybrid AD user $SamAccountName" -Rethrow -ScriptBlock {
    . (Join-Path $PSScriptRoot 'Invoke-OnPremSession.ps1') -TenantName $TenantName -ScriptBlock {
        param($SamAccountName,$MoveToDisabledOU,$DisabledOu,$RemoveFromAllNonDefaultGroups)
        Import-Module ActiveDirectory
        $user = Get-ADUser -Identity $SamAccountName -Properties MemberOf,DistinguishedName
        Disable-ADAccount -Identity $user -Confirm:$false
        if ($RemoveFromAllNonDefaultGroups) {
            foreach ($groupDn in $user.MemberOf) {
                try {
                    Remove-ADGroupMember -Identity $groupDn -Members $user.SamAccountName -Confirm:$false
                }
                catch {
                    Write-Warning "Failed to remove $($user.SamAccountName) from group $groupDn : $($_.Exception.Message)"
                }
            }
        }
        if ($MoveToDisabledOU -and -not [string]::IsNullOrWhiteSpace($DisabledOu)) {
            Move-ADObject -Identity $user.DistinguishedName -TargetPath $DisabledOu
        }
    } -ArgumentList @($SamAccountName,$MoveToDisabledOU,$tenant.OnPrem.OUPathDisabledUsers,$RemoveFromAllNonDefaultGroups)
}
