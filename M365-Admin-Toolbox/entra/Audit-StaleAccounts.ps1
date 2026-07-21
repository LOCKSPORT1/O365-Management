#Requires -Version 5.1
<#
.SYNOPSIS
    Flags AD accounts that are still enabled but haven't actually been used (on-prem or
    in the cloud) for longer than a threshold - the main way offboarding gets missed is
    that nobody re-checks "is this account still active" independent of HR telling you
    to run the offboarding script.

.DESCRIPTION
    This is a PORTABLE, VENDOR-NEUTRAL script - nothing environment-specific is hard-coded.
    It works against any AD domain / Entra tenant as-is; -ExcludeOU is the only thing you'd
    typically set (e.g. to skip the OU your offboarding script already parks disabled
    accounts in, since those are supposed to look inactive).

    For every ENABLED AD user account, this script:
      - Reads the AD account's own activity signal (LastLogonTimestamp - a replicated,
        cross-DC approximate value; see .NOTES for its accuracy caveats).
      - Looks the user up in Entra ID and reads their cloud sign-in activity
        (signInActivity.lastSignInDateTime), which is often more current than the AD
        attribute alone, especially for hybrid users who mostly sign into M365 apps.
      - Takes whichever of the two timestamps is more recent as "last known activity",
        so a user who's actually still active in one system isn't falsely flagged just
        because the other system's timestamp looks stale.
      - Flags the account if that most-recent activity is older than -InactiveDays, or if
        neither system has ever recorded a logon for it at all.

    This is READ-ONLY - it only reports, it never disables anything. Once you've reviewed
    the flagged list and confirmed which accounts are genuinely stale, run
    Offboard-HybridUser.ps1 against each one, or -CloudOnly if an
    account was already disabled elsewhere and just needs the rest of the cleanup.

.PARAMETER InactiveDays
    Number of days of no sign-in activity (AD or Entra, whichever is more recent) before
    an enabled account is flagged. Defaults to 90.

.PARAMETER SearchBase
    Optional AD OU (distinguished name) to limit the scan to. Omit to scan the whole
    domain, which is the normal use case for this audit.

.PARAMETER ExcludeOU
    One or more OU distinguished names to skip entirely (e.g. your shared-mailbox /
    disabled-users OU, since accounts there are already offboarded and expected to look
    inactive - flagging them again is just noise). Accepts multiple values.

.PARAMETER ReportPath
    Folder to write the CSV report and transcript log to. Defaults to .\AuditReports.

.PARAMETER AutoInstallMissingModules
    If a required PSGallery module isn't installed, install it automatically instead
    of prompting. The ActiveDirectory module (RSAT) can never be auto-installed this way.

.EXAMPLE
    .\Audit-StaleAccounts.ps1
    Flags every enabled AD account domain-wide with no activity in 90+ days.

.EXAMPLE
    .\Audit-StaleAccounts.ps1 -InactiveDays 60 -ExcludeOU "OU=Shared Mailboxes,OU=Users,DC=contoso,DC=com"
    Tighter 60-day threshold, skipping the OU where already-offboarded accounts live.

.EXAMPLE
    .\Audit-StaleAccounts.ps1 -SearchBase "OU=Users,DC=contoso,DC=com"
    Only scans a specific OU instead of the whole domain.

.NOTES
    Required modules  : ActiveDirectory, Microsoft.Graph.Users
    Required Graph scopes (delegated or app-only) : User.Read.All, AuditLog.Read.All
                        (AuditLog.Read.All is what unlocks the SignInActivity property -
                        without it, Get-MgUser silently returns $null for that field and
                        this script falls back to AD-only activity for that user, noted
                        in the report Detail column so you know cloud data was unavailable
                        rather than assuming the cloud side genuinely has no activity).

    LastLogonTimestamp ACCURACY: this AD attribute is replicated between domain
    controllers but only updates every 9-14 days by design (to limit replication
    traffic), so it's an approximation, not a precise "last logon" - a user who logged
    on 3 days ago may still show a LastLogonTimestamp from 10 days ago. This script
    treats it as approximate and pairs it with Entra's sign-in activity (which is
    real-time) to reduce false positives; it does not query LastLogon (unreplicated,
    per-DC, accurate but requires querying every DC individually) since that's
    significantly more expensive to gather across a multi-DC environment.

    A flagged account is NOT necessarily safe to offboard immediately - service
    accounts, break-glass accounts, and seasonal/leave-of-absence users can legitimately
    show no activity for a while. Review the flagged list before acting on it.
#>

[CmdletBinding()]
param(
    [int]$InactiveDays = 90,

    [string]$SearchBase,

    [string[]]$ExcludeOU,

    [string]$ReportPath = ".\AuditReports",

    [switch]$AutoInstallMissingModules
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[Object]

function Add-Result {
    param($User, $Category, $Status, $Detail = "")
    $results.Add([PSCustomObject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        User      = $User
        Category  = $Category
        Status    = $Status
        Detail    = $Detail
    })
}

# Ensures a required module is available, importing it if present, offering to install it
# if it's missing and comes from PSGallery, or explaining how to get it if it doesn't
# (currently only ActiveDirectory/RSAT, which is a Windows feature, not a gallery module).
function Ensure-Module {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ManualInstallHint,
        [switch]$IsWindowsFeature
    )
    if (Get-Module -ListAvailable -Name $Name) {
        Import-Module -Name $Name -ErrorAction Stop
        return
    }
    if ($IsWindowsFeature) {
        throw "Required module '$Name' isn't installed, and it can't be installed from PSGallery - it comes from RSAT. $ManualInstallHint"
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
    }
    catch {
        throw "Failed to install '$Name' automatically: $($_.Exception.Message) $ManualInstallHint"
    }
}

if (-not (Test-Path $ReportPath)) {
    New-Item -Path $ReportPath -ItemType Directory -Force | Out-Null
}
$transcriptFile = Join-Path $ReportPath "AuditStaleAccounts_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $transcriptFile -Append | Out-Null

Write-Host "=== Auditing for stale (enabled but inactive $InactiveDays+ days) accounts ===" -ForegroundColor Cyan

#region 1. Load / verify modules
Ensure-Module -Name 'ActiveDirectory' -IsWindowsFeature -ManualInstallHint (
    "Windows 10/11: Settings > Optional Features > Add a feature > 'RSAT: Active Directory " +
    "Domain Services and Lightweight Directory Tools' (or run, as admin: " +
    "Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0). " +
    "Windows Server: Install-WindowsFeature RSAT-AD-PowerShell."
)
Ensure-Module -Name 'Microsoft.Graph.Users' -ManualInstallHint "Install-Module Microsoft.Graph.Users -Scope CurrentUser"
#endregion

#region 2. Connect to Graph once, up front
try {
    if (-not (Get-MgContext)) {
        Connect-MgGraph -Scopes "User.Read.All", "AuditLog.Read.All" -NoWelcome
    }
}
catch {
    Write-Warning "Could not connect to Microsoft Graph: $($_.Exception.Message). Cloud sign-in data will be unavailable - falling back to AD-only activity for every account."
}
#endregion

#region 3. Enumerate enabled AD accounts
$getAdUserParams = @{
    Filter     = 'Enabled -eq $true'
    Properties = 'LastLogonTimestamp', 'UserPrincipalName', 'DistinguishedName', 'whenCreated'
}
if ($SearchBase) { $getAdUserParams.SearchBase = $SearchBase }

$adUsers = Get-ADUser @getAdUserParams
Write-Host "Found $($adUsers.Count) enabled AD account(s) to evaluate.`n"

if ($ExcludeOU -and $ExcludeOU.Count -gt 0) {
    $before = $adUsers.Count
    $adUsers = $adUsers | Where-Object {
        $dn = $_.DistinguishedName
        -not ($ExcludeOU | Where-Object { $dn -like "*$_" })
    }
    Write-Host "Excluded $($before - $adUsers.Count) account(s) under -ExcludeOU."
}
#endregion

#region 4. Evaluate each account
$cutoff = (Get-Date).AddDays(-$InactiveDays)
$flaggedCount = 0

foreach ($adUser in $adUsers) {
    $sam = $adUser.SamAccountName
    $upn = $adUser.UserPrincipalName

    $adLastLogon = $null
    if ($adUser.LastLogonTimestamp) {
        $adLastLogon = [DateTime]::FromFileTime($adUser.LastLogonTimestamp)
    }

    $entraLastSignIn = $null
    $entraDataAvailable = $false
    if ($upn -and (Get-MgContext)) {
        try {
            $mgUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property Id, UserPrincipalName, SignInActivity -ErrorAction SilentlyContinue
            if ($mgUser -and $mgUser.SignInActivity -and $mgUser.SignInActivity.LastSignInDateTime) {
                $entraLastSignIn = [DateTime]$mgUser.SignInActivity.LastSignInDateTime
                $entraDataAvailable = $true
            }
            elseif ($mgUser) {
                $entraDataAvailable = $true
            }
        }
        catch {
            # Leave $entraDataAvailable = $false - noted in the report below
        }
    }

    # Take whichever signal is more recent as "last known activity" - avoids false
    # positives for hybrid users who are mostly active in one system but not the other.
    $lastActivity = $null
    if ($adLastLogon -and $entraLastSignIn) {
        $lastActivity = if ($adLastLogon -gt $entraLastSignIn) { $adLastLogon } else { $entraLastSignIn }
    }
    elseif ($adLastLogon) {
        $lastActivity = $adLastLogon
    }
    elseif ($entraLastSignIn) {
        $lastActivity = $entraLastSignIn
    }

    $detailSuffix = if (-not $entraDataAvailable) { " (cloud sign-in data unavailable - AuditLog.Read.All not granted, or Graph not connected; AD-only comparison)" } else { "" }

    if (-not $lastActivity) {
        $flaggedCount++
        Add-Result $sam "Activity" "Flagged" "No recorded logon in AD or Entra at all (account created $($adUser.whenCreated.ToString('yyyy-MM-dd')))$detailSuffix"
        continue
    }

    if ($lastActivity -lt $cutoff) {
        $flaggedCount++
        $daysInactive = [Math]::Round(((Get-Date) - $lastActivity).TotalDays)
        Add-Result $sam "Activity" "Flagged" "Last activity $($lastActivity.ToString('yyyy-MM-dd')) - $daysInactive day(s) ago (AD: $(if ($adLastLogon) { $adLastLogon.ToString('yyyy-MM-dd') } else { 'never' }), Entra: $(if ($entraLastSignIn) { $entraLastSignIn.ToString('yyyy-MM-dd') } else { 'never/unavailable' }))$detailSuffix"
    }
    else {
        Add-Result $sam "Activity" "OK" "Last activity $($lastActivity.ToString('yyyy-MM-dd')) - within $InactiveDays day threshold$detailSuffix"
    }
}
#endregion

#region 5. Report
$reportFile = Join-Path $ReportPath "AuditStaleAccounts_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $reportFile -NoTypeInformation

Write-Host "`n=== Audit summary ===" -ForegroundColor Cyan
Write-Host "Accounts evaluated : $($adUsers.Count)"
Write-Host "Accounts flagged   : $flaggedCount (enabled, no activity in $InactiveDays+ days)"
Write-Host "Full report: $reportFile"
Write-Host "`nReview flagged accounts before offboarding - service accounts, break-glass accounts, and leave-of-absence users can legitimately show no recent activity." -ForegroundColor Yellow

Stop-Transcript | Out-Null
#endregion
