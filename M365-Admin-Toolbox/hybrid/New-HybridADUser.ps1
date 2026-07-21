<#
.SYNOPSIS
    Creates a new hybrid (on-prem synced) Active Directory user account.

.DESCRIPTION
    Connects to the tenant's configured on-prem domain controller / management host
    and creates a new AD user in the tenant's configured users OU. Optionally adds
    the new account to one or more on-prem groups. Intended for hybrid tenants where
    identities are sourced from on-prem AD and synchronized to Entra ID via
    AAD/Entra Connect (run Start-ADSync.ps1 afterward to push the new account to the cloud).

    SECURITY NOTE: no default initial password is supplied. You must either pass
    -InitialPassword explicitly or let the script generate a random one (default
    behavior), which is written to the log/console once so it can be relayed to the
    user through a secure channel. The account is always created with
    ChangePasswordAtLogon so the temporary password cannot be reused long-term.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json. Used to resolve the
    on-prem remote host and users OU path from the tenant's OnPrem configuration block.

.PARAMETER SamAccountName
    The sAMAccountName for the new on-prem AD user.

.PARAMETER UserPrincipalName
    The UPN for the new user. Accepts either a full UPN (e.g. jdoe@corp.contoso.com) or just the
    local part (e.g. jdoe) - if no '@' is present, the tenant's PrimaryDomain from
    config\tenants.json is appended automatically via Resolve-ToolboxUserPrincipalName.

.PARAMETER DisplayName
    Display name for the new user.

.PARAMETER GivenName
    First name.

.PARAMETER Surname
    Last name.

.PARAMETER Department
    Optional department attribute.

.PARAMETER JobTitle
    Optional job title attribute.

.PARAMETER OfficeLocation
    Optional office attribute.

.PARAMETER InitialPassword
    Optional initial password. If omitted, a random password meeting the
    configured length requirement is generated. The account is created with
    ChangePasswordAtLogon so this is a one-time temporary password only.

.PARAMETER OnPremGroups
    Optional list of on-prem AD group names/DNs to add the new user to.

.EXAMPLE
    .\New-HybridADUser.ps1 -TenantName 'Contoso' -SamAccountName 'jdoe' `
        -UserPrincipalName 'jdoe@corp.contoso.com' -DisplayName 'Jane Doe' `
        -GivenName 'Jane' -Surname 'Doe' -Department 'Finance' -OnPremGroups @('Finance-Team')

    Creates jdoe in the tenant's configured users OU with a randomly generated
    temporary password and adds her to the Finance-Team group.
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [Parameter(Mandatory)][string]$SamAccountName,
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$GivenName,
    [Parameter(Mandatory)][string]$Surname,
    [string]$Department,
    [string]$JobTitle,
    [string]$OfficeLocation,
    [string]$InitialPassword,
    [string[]]$OnPremGroups = @()
)

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Length of the randomly generated temporary password when -InitialPassword is not supplied
$GeneratedPasswordLength = 16

$tenant = Get-TenantConfig -TenantName $TenantName
$UserPrincipalName = Resolve-ToolboxUserPrincipalName -UserPrincipalName $UserPrincipalName -Tenant $tenant

if ([string]::IsNullOrWhiteSpace($InitialPassword)) {
    Add-Type -AssemblyName System.Web
    $InitialPassword = [System.Web.Security.Membership]::GeneratePassword($GeneratedPasswordLength, 4)
    Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "No -InitialPassword supplied; generated a random temporary password for $SamAccountName. Relay it to the user via a secure channel."
}

Invoke-ToolboxSafely -TenantName $TenantName -Operation "Create hybrid AD user $SamAccountName" -Rethrow -ScriptBlock {
    . (Join-Path $PSScriptRoot 'Invoke-OnPremSession.ps1') -TenantName $TenantName -ScriptBlock {
        param($SamAccountName,$UserPrincipalName,$DisplayName,$GivenName,$Surname,$Department,$JobTitle,$OfficeLocation,$InitialPassword,$OUPathUsers,$OnPremGroups)
        Import-Module ActiveDirectory
        $secure = ConvertTo-SecureString $InitialPassword -AsPlainText -Force
        New-ADUser -SamAccountName $SamAccountName -UserPrincipalName $UserPrincipalName -Name $DisplayName -DisplayName $DisplayName -GivenName $GivenName -Surname $Surname -Department $Department -Title $JobTitle -Office $OfficeLocation -Path $OUPathUsers -Enabled $true -ChangePasswordAtLogon $true -AccountPassword $secure
        foreach ($group in $OnPremGroups) {
            if (-not [string]::IsNullOrWhiteSpace($group)) {
                try {
                    Add-ADGroupMember -Identity $group -Members $SamAccountName
                }
                catch {
                    Write-Warning "Failed to add $SamAccountName to group $group : $($_.Exception.Message)"
                }
            }
        }
    } -ArgumentList @($SamAccountName,$UserPrincipalName,$DisplayName,$GivenName,$Surname,$Department,$JobTitle,$OfficeLocation,$InitialPassword,$tenant.OnPrem.OUPathUsers,$OnPremGroups)
}
