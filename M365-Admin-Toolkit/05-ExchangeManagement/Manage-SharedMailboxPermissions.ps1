<#
.SYNOPSIS
    Adds, removes, or audits Full Access / Send As / Send on Behalf
    permissions on a shared (or regular) mailbox.

.DESCRIPTION
    One script for the three permission verbs instead of remembering three
    different cmdlet names and syntaxes. Also supports -Action Audit to
    just list current delegates, which is the most common ask ("who has
    access to the billing mailbox?").

.NOTES
    Self-connects to Exchange Online automatically if not already connected
    (see -AuthMode param; defaults to Interactive). No manual dot-sourcing
    required - Connect-M365Services.ps1 is called internally.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MailboxIdentity,
    [ValidateSet("Add","Remove","Audit")]
    [Parameter(Mandatory)][string]$Action,
    [ValidateSet("FullAccess","SendAs","SendOnBehalf")]
    [string]$PermissionType,
    [string]$TargetUser,
    # NOTE: [bool] (not [switch]) so the CONFIGURATION default below can be
    # overridden with -AutoMapping:$false - a [switch] can't be "on by
    # default but toggle-off-able" the way callers expect.
    [bool]$AutoMapping,

    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Default permission type applied when -PermissionType is not specified is
# NOT set here on purpose (Add/Remove require an explicit choice - see check
# below); this default only covers whether AutoMapping is on by default.
if (-not $PSBoundParameters.ContainsKey('AutoMapping')) { $AutoMapping = $true }

if ($Action -in @("Add","Remove") -and (-not $PermissionType -or -not $TargetUser)) {
    Write-Error "Add/Remove require both -PermissionType and -TargetUser."
    return
}

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services ExchangeOnline -AuthMode $AuthMode
#endregion


switch ($Action) {
    "Audit" {
        Write-Host "=== Current delegates on $MailboxIdentity ===" -ForegroundColor Cyan

        Write-Host "`nFull Access:" -ForegroundColor Yellow
        Get-MailboxPermission -Identity $MailboxIdentity |
            Where-Object { $_.User -notlike "NT AUTHORITY\*" -and $_.IsInherited -eq $false } |
            Select-Object User, AccessRights | Format-Table -AutoSize

        Write-Host "Send As:" -ForegroundColor Yellow
        Get-RecipientPermission -Identity $MailboxIdentity |
            Where-Object { $_.Trustee -notlike "NT AUTHORITY\*" } |
            Select-Object Trustee, AccessRights | Format-Table -AutoSize

        Write-Host "Send on Behalf:" -ForegroundColor Yellow
        (Get-Mailbox -Identity $MailboxIdentity).GrantSendOnBehalfTo | ForEach-Object { Write-Host "  $_" }
    }

    "Add" {
        try {
            switch ($PermissionType) {
                "FullAccess" {
                    Add-MailboxPermission -Identity $MailboxIdentity -User $TargetUser -AccessRights FullAccess -AutoMapping:$AutoMapping
                }
                "SendAs" {
                    Add-RecipientPermission -Identity $MailboxIdentity -Trustee $TargetUser -AccessRights SendAs -Confirm:$false
                }
                "SendOnBehalf" {
                    Set-Mailbox -Identity $MailboxIdentity -GrantSendOnBehalfTo @{Add=$TargetUser}
                }
            }
            Write-Host "[OK] Granted $PermissionType to $TargetUser on $MailboxIdentity" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to grant $PermissionType to $TargetUser on $MailboxIdentity - $_"
        }
    }

    "Remove" {
        try {
            switch ($PermissionType) {
                "FullAccess" {
                    Remove-MailboxPermission -Identity $MailboxIdentity -User $TargetUser -AccessRights FullAccess -Confirm:$false
                }
                "SendAs" {
                    Remove-RecipientPermission -Identity $MailboxIdentity -Trustee $TargetUser -AccessRights SendAs -Confirm:$false
                }
                "SendOnBehalf" {
                    Set-Mailbox -Identity $MailboxIdentity -GrantSendOnBehalfTo @{Remove=$TargetUser}
                }
            }
            Write-Host "[OK] Removed $PermissionType from $TargetUser on $MailboxIdentity" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to remove $PermissionType from $TargetUser on $MailboxIdentity - $_"
        }
    }
}
