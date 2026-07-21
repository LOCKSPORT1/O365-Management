<#
.SYNOPSIS
    Full offboarding workflow: disable sign-in, revoke sessions, convert
    mailbox to shared, remove licenses, clean up group memberships,
    set out-of-office, and optionally disable/move the on-prem AD account.

.DESCRIPTION
    Runs as a single ordered pipeline so nothing gets forgotten on a rushed
    exit. Every step is wrapped so one failure doesn't kill the rest of the
    run - failures are collected and reported at the end. Supports
    -WhatIf/-Confirm (SupportsShouldProcess) so you can dry-run the whole
    pipeline before committing to destructive/irreversible-ish actions
    (license removal, mailbox conversion, group removal, AD disable/move).

.PARAMETER UserUpn
    UserPrincipalName of the account being offboarded. Mandatory.

.PARAMETER ManagerUpn
    Optional. If provided, the manager is granted Full Access to the
    converted shared mailbox and is referenced in the out-of-office message.

.PARAMETER ConvertMailboxToShared
    Switch. Converts the mailbox to a shared mailbox (preserves mail
    history, frees the license) instead of leaving it as a user mailbox.

.PARAMETER RevokeSessions
    Switch. Invalidates refresh tokens to kill active sign-ins immediately.

.PARAMETER RemoveLicenses
    Switch. Strips all currently assigned license SKUs from the user.

.PARAMETER DisableOnPremAD
    Switch. Disables the on-prem AD account (hybrid-synced accounts only).
    Requires the ActiveDirectory module and network access to a DC.

.PARAMETER SetOutOfOffice
    Switch. Enables an internal/external auto-reply using -OutOfOfficeMessage.

.PARAMETER OutOfOfficeMessage
    Message template used for the auto-reply. `{0}` is replaced with
    -ManagerUpn if supplied.

.PARAMETER AddToAD_DisabledOU
    Switch. Also moves the on-prem AD object into the configured Disabled
    Users OU. Only applies when -DisableOnPremAD is also specified.

.PARAMETER AuthMode
    Interactive, AppSecret, or Certificate. Passed through to
    Assert-M365Connection. Defaults to Interactive.

.EXAMPLE
    .\Invoke-M365UserOffboarding.ps1 -UserUpn "jane.doe@yourdomain.com" `
        -ManagerUpn "john.smith@yourdomain.com" `
        -ConvertMailboxToShared -RevokeSessions -RemoveLicenses `
        -SetOutOfOffice -DisableOnPremAD -AddToAD_DisabledOU

.EXAMPLE
    # Dry run - shows what would happen without making any changes
    .\Invoke-M365UserOffboarding.ps1 -UserUpn "jane.doe@yourdomain.com" `
        -ConvertMailboxToShared -RevokeSessions -RemoveLicenses -WhatIf

.NOTES
    Self-connects to both Graph and Exchange Online automatically if not
    already connected (see -AuthMode param; defaults to Interactive).
    Run ActiveDirectory steps on/near a DC if using -DisableOnPremAD.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$UserUpn,
    [string]$ManagerUpn,                          # if provided, mailbox delegate access + group ownership transfer target
    [switch]$ConvertMailboxToShared,
    [switch]$RevokeSessions,
    [switch]$RemoveLicenses,
    [switch]$DisableOnPremAD,
    [switch]$SetOutOfOffice,
    [string]$OutOfOfficeMessage = "I am no longer with the company. Please contact {0} for assistance.",
    [switch]$AddToAD_DisabledOU,

    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$Config = @{
    # Distinguished name of the OU disabled AD accounts get moved into (only used with -AddToAD_DisabledOU)
    ADDisabledOU         = "OU=Disabled Users,DC=yourdomain,DC=local"
    # Domain controller (FQDN) used for ActiveDirectory cmdlets
    ADServer             = "dc01.yourdomain.local"
    # Display name of an optional holding/retention group offboarded users are added to instead of losing all group visibility immediately
    RetentionGroupTag    = "SG-FormerEmployees-Retention"
    # Note/reminder only - pair with your NinjaRMM custom-field automation if you want the offboarding date tracked there too
    NinjaCustomFieldNote = "OffboardedDate"
    # Default fallback text used in the out-of-office message when -ManagerUpn is not supplied
    NoManagerContactText = "your manager or the IT helpdesk"
}

#region Connect - ensures required sessions are live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph,ExchangeOnline -AuthMode $AuthMode
#endregion

$errors = @()
$user = Get-MgUser -Filter "userPrincipalName eq '$UserUpn'" -Property Id,DisplayName,UserPrincipalName,AssignedLicenses
if (-not $user) {
    Write-Error "User $UserUpn not found in Entra ID. Aborting."
    return
}
Write-Host "Offboarding $($user.DisplayName) ($UserUpn)..." -ForegroundColor Cyan

# 1. Disable sign-in immediately
if ($PSCmdlet.ShouldProcess($UserUpn, "Disable account sign-in")) {
    try {
        Update-MgUser -UserId $user.Id -AccountEnabled:$false
        Write-Host "[OK] Account sign-in disabled." -ForegroundColor Green
    } catch { $errors += "Disable account: $_" }
}

# 2. Revoke all active sessions/refresh tokens
if ($RevokeSessions) {
    if ($PSCmdlet.ShouldProcess($UserUpn, "Revoke active sessions/refresh tokens")) {
        try {
            Invoke-MgInvalidateUserRefreshToken -UserId $user.Id
            Write-Host "[OK] Sessions revoked." -ForegroundColor Green
        } catch { $errors += "Revoke sessions: $_" }
    }
}

# 3. Reset password to a random value (belt-and-suspenders alongside disabling)
if ($PSCmdlet.ShouldProcess($UserUpn, "Reset password to random value")) {
    try {
        Add-Type -AssemblyName System.Web
        $randomPwd = [System.Web.Security.Membership]::GeneratePassword(24, 6)
        Update-MgUser -UserId $user.Id -PasswordProfile @{ Password = $randomPwd; ForceChangePasswordNextSignIn = $true }
        Write-Host "[OK] Password reset to random value." -ForegroundColor Green
    } catch { $errors += "Password reset: $_" }
}

# 4. Convert mailbox to shared (preserves mail history, no license needed)
if ($ConvertMailboxToShared) {
    if ($PSCmdlet.ShouldProcess($UserUpn, "Convert mailbox to shared")) {
        try {
            Set-Mailbox -Identity $UserUpn -Type Shared
            Write-Host "[OK] Mailbox converted to shared." -ForegroundColor Green
            if ($ManagerUpn) {
                if ($PSCmdlet.ShouldProcess($UserUpn, "Grant $ManagerUpn Full Access to mailbox")) {
                    Add-MailboxPermission -Identity $UserUpn -User $ManagerUpn -AccessRights FullAccess -AutoMapping $true
                    Write-Host "[OK] Full access granted to $ManagerUpn." -ForegroundColor Green
                }
            }
        } catch { $errors += "Mailbox conversion: $_" }
    }
}

# 5. Set out-of-office / auto-reply
if ($SetOutOfOffice) {
    if ($PSCmdlet.ShouldProcess($UserUpn, "Set out-of-office auto-reply")) {
        try {
            $contact = if ($ManagerUpn) { $ManagerUpn } else { $Config.NoManagerContactText }
            $msg = $OutOfOfficeMessage -f $contact
            Set-MailboxAutoReplyConfiguration -Identity $UserUpn -AutoReplyState Enabled `
                -InternalMessage $msg -ExternalMessage $msg
            Write-Host "[OK] Auto-reply configured." -ForegroundColor Green
        } catch { $errors += "Auto-reply: $_" }
    }
}

# 6. Remove licenses (do this AFTER mailbox conversion so Exchange settings stick)
if ($RemoveLicenses) {
    try {
        $current = Get-MgUser -UserId $user.Id -Property AssignedLicenses
        $skuIds = $current.AssignedLicenses.SkuId
        if ($skuIds) {
            if ($PSCmdlet.ShouldProcess($UserUpn, "Remove $($skuIds.Count) license(s)")) {
                Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $skuIds
                Write-Host "[OK] Removed $($skuIds.Count) license(s)." -ForegroundColor Green
            }
        } else {
            Write-Host "[INFO] No licenses assigned." -ForegroundColor Yellow
        }
    } catch { $errors += "License removal: $_" }
}

# 7. Remove from all groups except retention/holding group
try {
    $memberships = Get-MgUserMemberOf -UserId $user.Id
    foreach ($m in $memberships) {
        if ($m.AdditionalProperties.displayName -eq $Config.RetentionGroupTag) { continue }
        if ($PSCmdlet.ShouldProcess($UserUpn, "Remove from group $($m.AdditionalProperties.displayName)")) {
            try {
                Remove-MgGroupMemberByRef -GroupId $m.Id -DirectoryObjectId $user.Id
            } catch {
                # some memberships (dynamic groups, role-assignable groups) can't be removed this way - log and move on
                $errors += "Remove from group $($m.AdditionalProperties.displayName): $_"
            }
        }
    }
    Write-Host "[OK] Group memberships cleared (except retention group, if configured)." -ForegroundColor Green
} catch { $errors += "Group cleanup: $_" }

# 8. Add to retention/holding group for visibility during the exit window
if ($Config.RetentionGroupTag) {
    try {
        $retGroup = Get-MgGroup -Filter "displayName eq '$($Config.RetentionGroupTag)'"
        if ($retGroup) {
            if ($PSCmdlet.ShouldProcess($UserUpn, "Add to retention group $($Config.RetentionGroupTag)")) {
                New-MgGroupMember -GroupId $retGroup.Id -DirectoryObjectId $user.Id
            }
        }
    } catch { $errors += "Retention group add: $_" }
}

# 9. On-prem AD: disable + move to Disabled OU (only if hybrid-synced account)
if ($DisableOnPremAD) {
    if ($PSCmdlet.ShouldProcess($UserUpn, "Disable on-prem AD account$(if($AddToAD_DisabledOU){' and move to Disabled OU'})")) {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $samName = ($UserUpn -split '@')[0]
            Disable-ADAccount -Identity $samName -Server $Config.ADServer
            if ($AddToAD_DisabledOU) {
                Get-ADUser -Identity $samName -Server $Config.ADServer | Move-ADObject -TargetPath $Config.ADDisabledOU -Server $Config.ADServer
            }
            Write-Host "[OK] On-prem AD account disabled$(if($AddToAD_DisabledOU){' and moved to Disabled OU'})." -ForegroundColor Green
        } catch { $errors += "On-prem AD disable: $_" }
    }
}

Write-Host "`n===== Offboarding summary for $UserUpn =====" -ForegroundColor Cyan
if ($errors.Count -eq 0) {
    Write-Host "All steps completed with no errors." -ForegroundColor Green
} else {
    Write-Host "$($errors.Count) step(s) had issues - review below:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
}
Write-Host "Reminder: this script does NOT touch Intune device retire/wipe or AnyDesk/CrowdStrike deauth - see 03-DeviceLifecycle for that half of offboarding."
