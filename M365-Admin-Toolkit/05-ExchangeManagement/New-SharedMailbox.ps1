<#
.SYNOPSIS
    Creates a shared mailbox, sets size/auto-expanding archive, and grants
    initial Full Access + Send As delegates.

.DESCRIPTION
    Shared mailboxes don't need a license under 50GB, so this is meant to
    be the standard path any time someone asks for a departmental/shared
    inbox (e.g. billing@, support@, credit-desk@) rather than spinning up
    a full user for it.

.NOTES
    Self-connects to Exchange Online automatically if not already connected
    (see -AuthMode param; defaults to Interactive). No manual dot-sourcing
    required - Connect-M365Services.ps1 is called internally.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MailboxName,          # display name, e.g. "Accounts Receivable"
    [Parameter(Mandatory)][string]$PrimarySmtpAddress,   # e.g. billing@yourdomain.com
    [string[]]$FullAccessUsers = @(),
    [string[]]$SendAsUsers = @(),
    # NOTE: [bool] (not [switch]) so the CONFIGURATION default below can be
    # overridden with -AutoMapping:$false - a [switch] can't be "on by
    # default but toggle-off-able" the way callers expect.
    [bool]$AutoMapping,
    [switch]$EnableAutoExpandingArchive,
    [int]$ProvisioningWaitSeconds,

    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$Config = @{
    # Mailbox size limit (GB) to stay under the 50GB license-free threshold.
    DefaultProhibitSendReceiveQuotaGB = 49

    # Whether new shared mailboxes are hidden from the Global Address List.
    HideFromGAL = $false
}

# Whether delegates get automapping (mailbox auto-adds to their Outlook)
# unless -AutoMapping is explicitly passed.
if (-not $PSBoundParameters.ContainsKey('AutoMapping')) { $AutoMapping = $true }

# Seconds to wait after mailbox creation before setting further properties,
# to give AD/Exchange time to provision the new object.
if (-not $ProvisioningWaitSeconds) { $ProvisioningWaitSeconds = 15 }

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services ExchangeOnline -AuthMode $AuthMode
#endregion

Write-Host "Creating shared mailbox '$MailboxName' ($PrimarySmtpAddress)..." -ForegroundColor Cyan

try {
    New-Mailbox -Shared -Name $MailboxName -DisplayName $MailboxName -PrimarySmtpAddress $PrimarySmtpAddress
}
catch {
    Write-Error "Failed to create shared mailbox '$MailboxName' ($PrimarySmtpAddress): $_"
    return
}

# Give AD/Exchange a moment to provision before setting further properties
Start-Sleep -Seconds $ProvisioningWaitSeconds

try {
    Set-Mailbox -Identity $PrimarySmtpAddress `
        -ProhibitSendReceiveQuota "$($Config.DefaultProhibitSendReceiveQuotaGB)GB" `
        -HiddenFromAddressListsEnabled $Config.HideFromGAL
}
catch {
    Write-Warning "Mailbox was created, but failed to set quota/GAL visibility: $_"
}

if ($EnableAutoExpandingArchive) {
    try {
        Enable-Mailbox -Identity $PrimarySmtpAddress -AutoExpandingArchive
        Write-Host "[OK] Auto-expanding archive enabled." -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to enable auto-expanding archive: $_"
    }
}

foreach ($user in $FullAccessUsers) {
    try {
        Add-MailboxPermission -Identity $PrimarySmtpAddress -User $user -AccessRights FullAccess -AutoMapping:$AutoMapping
        Write-Host "[OK] Full Access granted to $user" -ForegroundColor Green
    } catch { Write-Warning "Failed to grant Full Access to $user - $_" }
}

foreach ($user in $SendAsUsers) {
    try {
        Add-RecipientPermission -Identity $PrimarySmtpAddress -Trustee $user -AccessRights SendAs -Confirm:$false
        Write-Host "[OK] Send As granted to $user" -ForegroundColor Green
    } catch { Write-Warning "Failed to grant Send As to $user - $_" }
}

Write-Host "`nShared mailbox '$MailboxName' created and configured." -ForegroundColor Cyan
Write-Host "Note: permission changes can take up to an hour to fully replicate/automap in Outlook."
