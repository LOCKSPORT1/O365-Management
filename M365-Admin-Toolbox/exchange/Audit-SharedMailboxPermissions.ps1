#Requires -Version 5.1
<#
.SYNOPSIS
    Audits Full Access, Send As, and Send on Behalf permissions on every shared mailbox
    in the tenant, and flags any grant held by an account that's since been disabled -
    permission grants left over from offboarding that nobody remembered to clean up.

.DESCRIPTION
    This is a PORTABLE, VENDOR-NEUTRAL script - it queries Exchange Online directly for
    every mailbox of type SharedMailbox tenant-wide (Get-Mailbox -RecipientTypeDetails
    SharedMailbox), so unlike Audit-SharedMailboxOU.ps1 it does NOT
    depend on a specific AD OU. That makes it a good complement to that script: this one
    catches permission drift on every shared mailbox regardless of where the underlying
    AD object (if any) lives, while Audit-SharedMailboxOU checks the fuller offboarding
    state (AD enabled/group membership/Entra state) for accounts specifically parked in
    your shared-mailbox OU.

    For every shared mailbox found, this script enumerates:
      - Full Access grants (Get-MailboxPermission), excluding the built-in NT
        AUTHORITY\SELF entry every mailbox has.
      - Send As grants (Get-RecipientPermission).
      - Send on Behalf grants (the mailbox's GrantSendOnBehalfTo property).

    For each individual (non-group) grantee, it looks up their AD account (if hybrid) or
    Entra ID account (if cloud-only) and flags the permission if that account is
    disabled - a classic sign that someone was offboarded but their lingering mailbox
    access to a shared mailbox was never explicitly revoked (Exchange doesn't do this
    automatically; disabling a user's own sign-in doesn't strip permissions THEY hold
    over OTHER mailboxes).

    Group-based grants are reported as informational only (Category "Info") rather than
    flagged, since this script doesn't expand group membership to check every member's
    account status - if you need that level of depth, audit the group's own membership
    directly instead.

    This is READ-ONLY - it only reports. Remove a flagged permission with
    Remove-MailboxPermission / Remove-RecipientPermission / Set-Mailbox
    -GrantSendOnBehalfTo once you've confirmed it should go.

.PARAMETER ReportPath
    Folder to write the CSV report and transcript log to. Defaults to .\AuditReports.

.PARAMETER AutoInstallMissingModules
    If a required PSGallery module isn't installed, install it automatically instead
    of prompting. The ActiveDirectory module (RSAT) can never be auto-installed this way,
    but it's only used opportunistically here (see .NOTES) - its absence doesn't stop
    the script from running.

.EXAMPLE
    .\Audit-SharedMailboxPermissions.ps1
    Audits every shared mailbox in the tenant for stale Full Access / Send As / Send on
    Behalf grants.

.NOTES
    Required modules  : ExchangeOnlineManagement, Microsoft.Graph.Users
                        (ActiveDirectory is used opportunistically if present, to resolve
                        a grantee's AD-enabled status directly for hybrid accounts; if
                        it's not installed, the script falls back to checking the
                        grantee's Entra ID AccountEnabled status instead, which is
                        still accurate for hybrid accounts since AD-disable eventually
                        syncs there - just not as instantly as checking AD directly)
    Required Graph scopes (delegated or app-only) : User.Read.All
    Required Exchange Online role : View-Only Recipients (or higher) is enough to read
                        every permission type this script checks; no write role needed
                        since remediation is manual by design.

    A grantee shown as "NotFound" means the permission entry references a security
    principal that no longer resolves to any user object (fully deleted account, or a
    SID left over from a account that was hard-deleted rather than just disabled) - these
    are generally safe to remove since there's no account left for them to matter to.
#>

[CmdletBinding()]
param(
    [string]$ReportPath = ".\AuditReports",

    [switch]$AutoInstallMissingModules
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[Object]

function Add-Result {
    param($Mailbox, $Category, $Grantee, $Status, $Detail = "")
    $results.Add([PSCustomObject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Mailbox   = $Mailbox
        Category  = $Category
        Grantee   = $Grantee
        Status    = $Status
        Detail    = $Detail
    })
}

# Ensures a required module is available, importing it if present, offering to install it
# if it's missing and comes from PSGallery, or explaining how to get it if it doesn't.
function Ensure-Module {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ManualInstallHint,
        [switch]$Optional
    )
    if (Get-Module -ListAvailable -Name $Name) {
        Import-Module -Name $Name -ErrorAction Stop
        return $true
    }
    if ($Optional) {
        return $false
    }
    Write-Warning "Required module '$Name' is not installed."
    $doInstall = $AutoInstallMissingModules -or $PSCmdlet.ShouldContinue(
        "Install '$Name' now from PSGallery for the current user?", "Missing module: $Name")
    if (-not $doInstall) {
        throw "'$Name' is required but not installed. $ManualInstallHint"
    }
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
        }
        $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Import-Module -Name $Name -ErrorAction Stop
        return $true
    }
    catch {
        throw "Failed to install '$Name' automatically: $($_.Exception.Message) $ManualInstallHint"
    }
}

if (-not (Test-Path $ReportPath)) {
    New-Item -Path $ReportPath -ItemType Directory -Force | Out-Null
}
$transcriptFile = Join-Path $ReportPath "AuditSharedMailboxPermissions_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $transcriptFile -Append | Out-Null

Write-Host "=== Auditing shared mailbox permissions tenant-wide ===" -ForegroundColor Cyan

#region 1. Load / verify modules and connect
Ensure-Module -Name 'ExchangeOnlineManagement' -ManualInstallHint "Install-Module ExchangeOnlineManagement -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Users' -ManualInstallHint "Install-Module Microsoft.Graph.Users -Scope CurrentUser"
$hasAD = Ensure-Module -Name 'ActiveDirectory' -Optional -ManualInstallHint "n/a (optional)"

if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
    Connect-ExchangeOnline -ShowBanner:$false
}
if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "User.Read.All" -NoWelcome
}
#endregion

# Resolves whether a grantee (by UPN/email) is disabled, checking AD first (if available
# and the account is hybrid) then falling back to Entra ID. Returns $null if the account
# can't be resolved at all (likely hard-deleted).
$enabledCache = @{}
function Test-GranteeDisabled {
    param([string]$Identity)
    if ($enabledCache.ContainsKey($Identity)) { return $enabledCache[$Identity] }

    $result = $null
    if ($hasAD) {
        try {
            $adMatch = Get-ADUser -Filter "UserPrincipalName -eq '$Identity' -or mail -eq '$Identity'" -Properties Enabled -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($adMatch) { $result = -not $adMatch.Enabled }
        }
        catch { }
    }
    if ($null -eq $result) {
        try {
            $mgMatch = Get-MgUser -Filter "userPrincipalName eq '$Identity' or mail eq '$Identity'" -Property AccountEnabled -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($mgMatch) { $result = -not $mgMatch.AccountEnabled }
        }
        catch { }
    }
    $enabledCache[$Identity] = $result
    return $result
}

#region 2. Enumerate shared mailboxes
$sharedMailboxes = Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited
Write-Host "Found $($sharedMailboxes.Count) shared mailbox(es) to audit.`n"
#endregion

#region 3. Audit each shared mailbox
foreach ($mbx in $sharedMailboxes) {
    $mbxId = $mbx.PrimarySmtpAddress
    Write-Host "--- $mbxId ---" -ForegroundColor Cyan

    # 3a. Full Access
    try {
        $fullAccessGrants = Get-MailboxPermission -Identity $mbx.Identity |
            Where-Object { $_.AccessRights -contains 'FullAccess' -and -not $_.IsInherited -and $_.User -notlike 'NT AUTHORITY\SELF' -and $_.Deny -eq $false }
    }
    catch {
        Add-Result $mbxId "FullAccess" "n/a" "Failed" "Could not read Full Access permissions: $($_.Exception.Message)"
        $fullAccessGrants = @()
    }
    foreach ($grant in $fullAccessGrants) {
        $granteeName = $grant.User.ToString()
        if ($granteeName -like '*\*' -or $granteeName -notlike '*@*') {
            # Looks like a security group or non-mail-enabled principal, not an
            # individual mailbox - can't resolve a single account's enabled state.
            Add-Result $mbxId "FullAccess" $granteeName "Info" "Grantee appears to be a group or non-user principal - audit its membership separately if needed"
            continue
        }
        $isDisabled = Test-GranteeDisabled -Identity $granteeName
        if ($null -eq $isDisabled) {
            Add-Result $mbxId "FullAccess" $granteeName "Info" "Grantee account could not be resolved in AD or Entra (possibly hard-deleted) - permission entry is likely safe to remove"
        }
        elseif ($isDisabled) {
            Add-Result $mbxId "FullAccess" $granteeName "Flagged" "Full Access held by a DISABLED account - stale permission from offboarding, safe to remove"
        }
        else {
            Add-Result $mbxId "FullAccess" $granteeName "OK" "Full Access held by an active account"
        }
    }

    # 3b. Send As
    try {
        $sendAsGrants = Get-RecipientPermission -Identity $mbx.Identity |
            Where-Object { $_.Trustee -notlike 'NT AUTHORITY\SELF' -and $_.AccessRights -contains 'SendAs' }
    }
    catch {
        Add-Result $mbxId "SendAs" "n/a" "Failed" "Could not read Send As permissions: $($_.Exception.Message)"
        $sendAsGrants = @()
    }
    foreach ($grant in $sendAsGrants) {
        $granteeName = $grant.Trustee.ToString()
        if ($granteeName -notlike '*@*') {
            Add-Result $mbxId "SendAs" $granteeName "Info" "Grantee appears to be a group or non-user principal - audit its membership separately if needed"
            continue
        }
        $isDisabled = Test-GranteeDisabled -Identity $granteeName
        if ($null -eq $isDisabled) {
            Add-Result $mbxId "SendAs" $granteeName "Info" "Grantee account could not be resolved in AD or Entra (possibly hard-deleted) - permission entry is likely safe to remove"
        }
        elseif ($isDisabled) {
            Add-Result $mbxId "SendAs" $granteeName "Flagged" "Send As held by a DISABLED account - stale permission from offboarding, safe to remove"
        }
        else {
            Add-Result $mbxId "SendAs" $granteeName "OK" "Send As held by an active account"
        }
    }

    # 3c. Send on Behalf
    $sendOnBehalfGrants = @($mbx.GrantSendOnBehalfTo)
    foreach ($grantee in $sendOnBehalfGrants) {
        if (-not $grantee) { continue }
        $granteeName = $grantee.ToString()
        $isDisabled = Test-GranteeDisabled -Identity $granteeName
        if ($null -eq $isDisabled) {
            Add-Result $mbxId "SendOnBehalf" $granteeName "Info" "Grantee could not be resolved directly by name - resolve manually via Get-Recipient '$granteeName'"
        }
        elseif ($isDisabled) {
            Add-Result $mbxId "SendOnBehalf" $granteeName "Flagged" "Send on Behalf held by a DISABLED account - stale permission from offboarding, safe to remove"
        }
        else {
            Add-Result $mbxId "SendOnBehalf" $granteeName "OK" "Send on Behalf held by an active account"
        }
    }

    if (-not $fullAccessGrants -and -not $sendAsGrants -and -not $sendOnBehalfGrants) {
        Add-Result $mbxId "Permissions" "n/a" "OK" "No individually-granted permissions found (beyond the default owner/SELF entries)"
    }
}
#endregion

#region 4. Report
$reportFile = Join-Path $ReportPath "AuditSharedMailboxPermissions_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $reportFile -NoTypeInformation

$flagged = $results | Where-Object { $_.Status -eq 'Flagged' }
Write-Host "`n=== Audit summary ===" -ForegroundColor Cyan
Write-Host "Shared mailboxes audited : $($sharedMailboxes.Count)"
Write-Host "Stale permissions flagged : $($flagged.Count)"
Write-Host "Full report: $reportFile"

Stop-Transcript | Out-Null
#endregion
