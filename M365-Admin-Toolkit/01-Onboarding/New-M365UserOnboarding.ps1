<#
.SYNOPSIS
    Creates a new M365 user (or preps an on-prem AD account for Entra sync)
    and stages it for licensing/group assignment.

.DESCRIPTION
    Two modes:
      - CloudOnly: creates the user directly in Entra ID via Graph.
      - HybridSync: creates the account in on-prem AD in the correct OU with
        the right attributes, then waits for/kicks an Entra Connect sync so
        it shows up in Entra ID before continuing. Use this if your source
        of truth is on-prem AD (this matches a synced hybrid AD/Entra setup).

    After the account exists, calls Add-UserToGroupsAndLicenses.ps1 to
    finish the job (license + group membership + usage location).

.PARAMETER FirstName
    New hire's first name. Used to build the display name, UPN, and mailNickname.

.PARAMETER LastName
    New hire's last name. Used to build the display name, UPN, and mailNickname.

.PARAMETER JobTitle
    Job title written to the AD/Entra job title attribute.

.PARAMETER Department
    Department name. Drives the license + group mapping consumed by
    Add-UserToGroupsAndLicenses.ps1 - must match a key in that script's
    $DepartmentLicenseMap / $DepartmentGroupMap (or falls back to "Default").

.PARAMETER ManagerUpn
    UPN of the new hire's manager. Looked up in Entra ID (CloudOnly) or
    on-prem AD (HybridSync) to set the manager attribute.

.PARAMETER Mode
    CloudOnly creates the user directly in Entra ID via Graph. HybridSync
    (default) creates the account in on-prem AD and waits for/kicks an
    Entra Connect delta sync.

.PARAMETER AuthMode
    Interactive, AppSecret, or Certificate - passed through to
    Assert-M365Connection / Connect-M365Services.ps1. Defaults to Interactive.

.EXAMPLE
    .\New-M365UserOnboarding.ps1 -FirstName "Jane" -LastName "Doe" `
        -JobTitle "Sales Associate" -Department "Sales" `
        -ManagerUpn "john.smith@yourdomain.com" -Mode HybridSync

    Creates an on-prem AD account for Jane Doe, waits for Entra Connect to
    sync it, then licenses/groups her via Add-UserToGroupsAndLicenses.ps1.

.EXAMPLE
    .\New-M365UserOnboarding.ps1 -FirstName "Jane" -LastName "Doe" `
        -JobTitle "Sales Associate" -Department "Sales" `
        -ManagerUpn "john.smith@yourdomain.com" -Mode CloudOnly -AuthMode AppSecret

    Creates a cloud-only Entra ID user (no on-prem AD involved) using
    app-only (client secret) authentication, suitable for a scheduled task.

.NOTES
    Run interactively as an admin the first few times before scheduling.
    Self-connects to Graph automatically if not already connected (see
    -AuthMode param; defaults to Interactive). No manual dot-sourcing
    required.
    HybridSync mode requires the ActiveDirectory module on a machine
    that can see the DC (e.g. run directly on the DC or a management host).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FirstName,
    [Parameter(Mandatory)][string]$LastName,
    [Parameter(Mandatory)][string]$JobTitle,
    [Parameter(Mandatory)][string]$Department,
    [Parameter(Mandatory)][string]$ManagerUpn,
    [ValidateSet("CloudOnly","HybridSync")]
    [string]$Mode = "HybridSync",

    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$Config = @{
    # ISO country code, required before licenses can be assigned
    UsageLocation              = "US"
    # UPN / primary email domain
    Domain                     = "yourdomain.com"
    # Length of the randomly generated temporary password
    DefaultPasswordLength      = 16
    # Forces the new user to change their password at first sign-in
    ForcePasswordChangeOnLogin = $true

    # Distinguished name of the OU new on-prem AD accounts land in (HybridSync mode only)
    ADTargetOU              = "OU=Users,DC=yourdomain,DC=local"
    # Domain controller to target for AD cmdlets (HybridSync mode only)
    ADServer                = "dc01.yourdomain.local"
    # Command run remotely on the Entra Connect server to force a delta sync (HybridSync mode only)
    EntraConnectSyncCommand = "Start-ADSyncSyncCycle -PolicyType Delta"
    # Hostname of your Entra Connect (AAD Connect) server (HybridSync mode only)
    EntraConnectServer      = "aadconnect01.yourdomain.local"
    # Seconds to wait after triggering a delta sync before checking Entra ID (HybridSync mode only)
    SyncWaitSeconds         = 90

    # Groups every new hire lands in regardless of department (e.g. All Staff, VPN access)
    BaselineGroups          = @("SG-AllStaff", "SG-VPN-Users")
}
# ============================================================

function New-RandomPassword {
    param([int]$Length = 16)
    Add-Type -AssemblyName System.Web
    return [System.Web.Security.Membership]::GeneratePassword($Length, 4)
}

$displayName = "$FirstName $LastName"
$mailNickname = "$FirstName.$LastName".ToLower() -replace '[^a-z0-9\.]', ''
$upn = "$mailNickname@$($Config.Domain)"

Write-Host "Provisioning $displayName ($upn) in $Mode mode..." -ForegroundColor Cyan

if ($Mode -eq "CloudOnly") {

    $tempPassword = New-RandomPassword -Length $Config.DefaultPasswordLength
    $passwordProfile = @{
        Password                      = $tempPassword
        ForceChangePasswordNextSignIn = $Config.ForcePasswordChangeOnLogin
    }

    try {
        $newUser = New-MgUser -DisplayName $displayName `
            -GivenName $FirstName `
            -Surname $LastName `
            -UserPrincipalName $upn `
            -MailNickname $mailNickname `
            -AccountEnabled:$true `
            -UsageLocation $Config.UsageLocation `
            -JobTitle $JobTitle `
            -Department $Department `
            -PasswordProfile $passwordProfile `
            -ErrorAction Stop

        Write-Host "Created cloud-only user: $($newUser.Id)" -ForegroundColor Green
        Write-Host "Temporary password: $tempPassword" -ForegroundColor Yellow
    }
    catch {
        Write-Error "Failed to create cloud-only user $upn - $($_.Exception.Message)"
        return
    }

    # Set manager
    $managerUser = Get-MgUser -Filter "userPrincipalName eq '$ManagerUpn'"
    if ($managerUser) {
        try {
            Set-MgUserManagerByRef -UserId $newUser.Id -BodyParameter @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($managerUser.Id)"
            } -ErrorAction Stop
            Write-Host "Manager set to $ManagerUpn" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to set manager for $upn - $($_.Exception.Message)"
        }
    }
    else {
        Write-Warning "Manager $ManagerUpn not found - set manually."
    }

    $script:CreatedUserId = $newUser.Id
    $script:CreatedUpn = $upn
}
else {
    # HybridSync mode - create in on-prem AD, then sync
    Import-Module ActiveDirectory -ErrorAction Stop

    $samAccountName = $mailNickname
    if ($samAccountName.Length -gt 20) { $samAccountName = $samAccountName.Substring(0,20) }

    $tempPassword = New-RandomPassword -Length $Config.DefaultPasswordLength
    $securePwd = ConvertTo-SecureString $tempPassword -AsPlainText -Force

    try {
        New-ADUser -Name $displayName `
            -GivenName $FirstName `
            -Surname $LastName `
            -SamAccountName $samAccountName `
            -UserPrincipalName $upn `
            -EmailAddress $upn `
            -Path $Config.ADTargetOU `
            -Title $JobTitle `
            -Department $Department `
            -AccountPassword $securePwd `
            -Enabled $true `
            -ChangePasswordAtLogon $Config.ForcePasswordChangeOnLogin `
            -Server $Config.ADServer `
            -ErrorAction Stop

        Write-Host "Created on-prem AD account: $samAccountName" -ForegroundColor Green
        Write-Host "Temporary password: $tempPassword" -ForegroundColor Yellow
    }
    catch {
        Write-Error "Failed to create on-prem AD account $samAccountName - $($_.Exception.Message)"
        return
    }

    # Set manager in AD (by distinguishedName lookup)
    $managerSam = ($ManagerUpn -split '@')[0]
    $managerDN = (Get-ADUser -Filter "UserPrincipalName -eq '$ManagerUpn'" -Server $Config.ADServer).DistinguishedName
    if ($managerDN) {
        Set-ADUser -Identity $samAccountName -Manager $managerDN -Server $Config.ADServer
    }
    else {
        Write-Warning "Manager $ManagerUpn not found in AD - set manually."
    }

    Write-Host "Triggering Entra Connect delta sync on $($Config.EntraConnectServer)..." -ForegroundColor Cyan
    try {
        Invoke-Command -ComputerName $Config.EntraConnectServer -ScriptBlock {
            param($cmd) Invoke-Expression $cmd
        } -ArgumentList $Config.EntraConnectSyncCommand -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to trigger Entra Connect sync on $($Config.EntraConnectServer) - $($_.Exception.Message)"
    }

    Write-Host "Waiting $($Config.SyncWaitSeconds)s for sync to propagate before checking Entra ID..." -ForegroundColor Cyan
    Start-Sleep -Seconds $Config.SyncWaitSeconds

    $script:CreatedUpn = $upn
    $synced = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
    if ($synced) {
        $script:CreatedUserId = $synced.Id
        Write-Host "Confirmed in Entra ID: $($synced.Id)" -ForegroundColor Green
    }
    else {
        Write-Warning "User not yet visible in Entra ID. Sync may still be propagating - re-run Add-UserToGroupsAndLicenses.ps1 manually once it appears."
    }
}

# Kick off group/license assignment if we have a confirmed Entra object
if ($script:CreatedUserId) {
    & "$PSScriptRoot\Add-UserToGroupsAndLicenses.ps1" `
        -UserId $script:CreatedUserId `
        -Department $Department `
        -AdditionalGroups $Config.BaselineGroups
}

Write-Host "`nOnboarding summary:" -ForegroundColor Cyan
Write-Host "  UPN: $script:CreatedUpn"
Write-Host "  Temp password: $tempPassword"
Write-Host "  Next: verify license + group assignment output above, notify helpdesk/manager."
