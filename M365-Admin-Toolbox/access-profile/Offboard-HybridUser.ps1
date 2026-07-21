#Requires -Version 5.1
<#
.SYNOPSIS
    Offboards a user in a hybrid Entra ID / on-prem Active Directory environment:
    disables the AD account, converts the mailbox to shared, removes all assigned Entra ID
    licenses, relocates the AD object to the shared-mailbox OU, strips the user from every
    AD group and every cloud (Entra ID) group they can be removed from, and revokes active
    cloud sessions.

.DESCRIPTION
    This is a PORTABLE, VENDOR-NEUTRAL template: nothing about a specific OU path,
    domain name, or tenant is hard-coded. Section "0. Configuration" below and the
    -SharedMailboxOU / -EntraConnectServer parameters are the only environment-specific
    inputs. See ".NOTES > Finding your environment-specific values" for exactly where
    to look those up in YOUR Active Directory / Entra tenant.

    Hybrid environments have TWO sources of truth for group membership:
      - Groups synced FROM on-prem AD via Entra Connect/AD Connect (OnPremisesSyncEnabled = $true)
        -> membership MUST be changed on-prem; Entra is read-only for these.
      - Cloud-native groups created directly in Entra ID / M365 (OnPremisesSyncEnabled = $false/$null)
        -> membership can only be changed via Graph/Exchange Online; AD has no knowledge of them.
    (Intune-assigned groups are ordinary Entra ID groups from a membership standpoint - the
    Graph-based cleanup below already covers them. No separate Intune module is required.)

    This script auto-detects which bucket each of the user's cloud group memberships falls
    into and routes the removal to the correct system instead of blindly trying both. Local
    AD groups are always handled via the ActiveDirectory module.

    The script does NOT assume ActiveDirectory / ExchangeOnlineManagement / Microsoft.Graph
    modules are already installed. It checks for each one and, if missing, either offers to
    install it for you (PSGallery modules) or tells you exactly how to get it (RSAT, which
    isn't a gallery module).

    Pipeline:
      1. Disable the on-prem AD account.
      2. Move the AD object to the shared-mailbox OU.
      3. Convert the user's mailbox to a shared mailbox (Exchange Online).
      4. Remove all assigned Entra ID licenses (skip with -SkipLicenseRemoval), run only
         after the mailbox conversion above so the license isn't pulled out from under an
         in-progress conversion.
      5. Remove the user from all local AD security/distribution groups (except primary group).
      6. Optionally trigger an Entra Connect delta sync and wait for it, so AD-side removals
         above propagate to Entra before step 7 evaluates cloud membership.
      7. Enumerate the user's Entra group memberships via Graph. For each:
           - Synced group  -> already handled in step 5; flagged and queued for the
             second-pass re-check in step 8.
           - Dynamic membership group -> skipped; membership is rule-based and can't be
             manually added/removed via any method, so don't waste a call / throw a 403.
           - Cloud-only security/M365 group -> remove via Microsoft Graph.
           - Cloud-only mail-enabled group (Distribution List / mail-enabled security group)
             -> Graph group-member removal is unreliable for these; fall back to
                Exchange Online (Remove-DistributionGroupMember).
      8. Wait -SyncRecheckWaitSeconds (default 90s, skip with -SkipSyncRecheck), then
         re-check every synced group flagged in step 7 and log whether it actually cleared
         or is still showing - Entra Connect's own replication can lag a bit past when the
         sync cycle itself reports complete, so this closes the loop instead of leaving a
         static warning you have to separately re-verify later.
      9. Revoke all active Entra refresh/session tokens and disable cloud sign-in
         (belt-and-suspenders alongside the AD disable, since Entra Connect sync of the
         disabled flag is not instant).
      10. Emit a per-user report (console + CSV) of every group evaluated and the outcome.

    Nothing here touches Intune device actions (retire/wipe) by design; scope was
    intentionally limited to account disable, mailbox conversion, license removal, and
    group membership cleanup.

    -CLOUDONLY MODE: if a prior run already completed the AD-side steps (disable, OU move,
    AD group removal) but you need to re-hit the cloud side again - most commonly to retry
    license removal after a permissions/scope issue, or to re-check cloud group cleanup -
    pass -CloudOnly -SamAccountName <name>. Steps 1, 2, and 5 above are skipped entirely
    (each logged as "Skipped" in the report) and everything else runs normally: mailbox
    conversion (unless -SkipMailboxConversion), license removal, sync trigger/wait, cloud
    group cleanup + recheck, and session revoke. Safe to re-run - none of these steps error
    out on something that's already done (e.g. removing a license that's already gone is
    just reported as "no licenses currently assigned").

.PARAMETER SamAccountName
    On-prem AD SamAccountName of the user being offboarded.

.PARAMETER CloudOnly
    Skip the on-prem AD steps (disable, OU move, AD group removal) and only run the cloud
    side: mailbox conversion, license removal, sync trigger/wait, cloud group cleanup, and
    session revoke. Use this to retry cloud-only steps (most commonly license removal) for
    a user whose AD-side work already completed successfully. See .DESCRIPTION above.

.PARAMETER SharedMailboxOU
    Distinguished name of the OU to move the disabled account into.
    No real-world default is baked in — the placeholder below will fail fast with
    instructions if you forget to set it. Either edit the default in section "0.
    Configuration" once for your environment, or pass -SharedMailboxOU every run.
    See .NOTES for how to find this value.

.PARAMETER SkipMailboxConversion
    Skip the Exchange Online shared-mailbox conversion step (e.g. user had no mailbox).

.PARAMETER SkipLicenseRemoval
    Opt-out switch. By default the script removes every Entra ID license currently
    assigned to the user (via Set-MgUserLicense) right after the mailbox conversion step.
    Pass this switch to leave licenses assigned (e.g. a temporary leave rather than a
    permanent offboarding).

.PARAMETER SkipEntraSyncWait
    Skip triggering/waiting on an Entra Connect delta sync before evaluating cloud groups.
    Only use this if you already know a sync has run recently, otherwise synced-group
    memberships may look "stuck" in step 6 simply because AD's removal hasn't replicated up yet.

.PARAMETER EntraConnectServer
    Hostname of the Entra Connect / AD Connect server, used to remotely trigger
    Start-ADSyncSyncCycle over PowerShell remoting. Omit if you trigger sync another way.
    See .NOTES for how to find this.

.PARAMETER SkipSyncRecheck
    Skip the second-pass re-check of synced groups that still showed the user as a member
    when first evaluated. Off by default - the script waits -SyncRecheckWaitSeconds and
    re-checks so the report shows whether they actually cleared.

.PARAMETER SyncRecheckWaitSeconds
    How long to wait before the second-pass re-check in .PARAMETER SkipSyncRecheck above.
    Defaults to 90 seconds. Increase this if your environment's Entra Connect -> Entra ID
    replication typically takes longer to catch up.

.PARAMETER ReportPath
    Folder to write the per-run CSV report and transcript log to. Defaults to .\OffboardingReports.

.PARAMETER AutoInstallMissingModules
    If a required PSGallery module (ExchangeOnlineManagement, Microsoft.Graph.*) isn't installed,
    install it automatically for the current user instead of prompting. The ActiveDirectory
    module (RSAT) can never be auto-installed this way - see .NOTES.

.PARAMETER WhatIf
    Standard ShouldProcess support - preview every change without making it.

.EXAMPLE
    .\Offboard-HybridUser.ps1 -SamAccountName jsmith -SharedMailboxOU "OU=Shared Mailboxes,DC=contoso,DC=com" -EntraConnectServer AADC01

.EXAMPLE
    .\Offboard-HybridUser.ps1 -SamAccountName jsmith -WhatIf
    (Uses whatever default is set in section "0. Configuration" below.)

.EXAMPLE
    .\Offboard-HybridUser.ps1 -SamAccountName jsmith -SharedMailboxOU "OU=Shared Mailboxes,DC=contoso,DC=com" -SkipLicenseRemoval

.EXAMPLE
    .\Offboard-HybridUser.ps1 -SamAccountName jsmith -CloudOnly
    (AD-side steps already completed in a prior run - just retries mailbox conversion,
    license removal, cloud group cleanup, and session revoke.)

.NOTES
    Required modules  : ActiveDirectory, ExchangeOnlineManagement,
                         Microsoft.Graph.Users, Microsoft.Graph.Groups,
                         Microsoft.Graph.Identity.DirectoryManagement,
                         Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Users.Actions
                         (Microsoft.Graph.Users.Actions is only checked/installed if
                         license removal actually runs, i.e. -SkipLicenseRemoval is not set)

    Version : see $Script:ScriptVersion in section 0 below - also printed in the startup
              banner and logged as the first row of every CSV report, so a saved report
              alone tells you whether that run had license removal / sync recheck / etc.
              If a report is missing features described in this help text, you were
              running an older copy - replace it with the current file from this folder.

    Required Graph scopes (delegated or app-only) :
                         User.ReadWrite.All, Group.ReadWrite.All,
                         GroupMember.ReadWrite.All, Directory.Read.All

    FINDING YOUR ENVIRONMENT-SPECIFIC VALUES
    -----------------------------------------
    SharedMailboxOU (the distinguished name of your shared-mailbox / disabled-users OU):
      - GUI: open Active Directory Users and Computers (dsa.msc) -> View menu -> check
        "Advanced Features" -> right-click the target OU -> Properties -> Attribute
        Editor tab -> find "distinguishedName" -> copy its value.
      - PowerShell (run on a machine with the ActiveDirectory module):
            Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName
        Look for the OU you use for disabled/shared-mailbox accounts.

    EntraConnectServer (only needed if you want this script to trigger a sync):
      - This is the hostname of whichever server has Microsoft Entra Connect (formerly
        Azure AD Connect) installed - check Programs and Features on your likely sync
        server, or ask whoever manages hybrid identity. You can confirm you have the
        right box by running, ON that server: Get-ADSyncScheduler
      - If you don't know it or don't want to grant remoting rights to it, omit
        -EntraConnectServer; the script still works, it just won't trigger a sync itself.

    Run this from an admin workstation with the ActiveDirectory RSAT module installed,
    or from a domain controller. Exchange Online / Graph connections happen over the
    internet regardless of where the script runs.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$SamAccountName,

    [switch]$CloudOnly,

    [string]$SharedMailboxOU,

    [switch]$SkipMailboxConversion,

    [switch]$SkipLicenseRemoval,

    [switch]$SkipEntraSyncWait,

    [string]$EntraConnectServer,

    [string]$ReportPath = ".\OffboardingReports",

    [int]$SyncWaitTimeoutSeconds = 300,

    [switch]$SkipSyncRecheck,

    [int]$SyncRecheckWaitSeconds = 90,

    [switch]$AutoInstallMissingModules
)

#region 0. Configuration
# ---------------------------------------------------------------------------------------
# Edit ONE thing here for your environment: the default Shared Mailbox / disabled-users
# OU. Once set, you no longer need to pass -SharedMailboxOU on every run (you can still
# override it per-run if some users need to land in a different OU).
#
# Leave the placeholder below as-is if you'd rather always pass -SharedMailboxOU
# explicitly - the script will tell you clearly if it's still unset when needed.
#
# See .NOTES above ("Finding your environment-specific values") for how to look this up.
# ---------------------------------------------------------------------------------------
$Script:DefaultSharedMailboxOU = "OU=CHANGE-ME,DC=CHANGE-ME,DC=CHANGE-ME"

# Bump this whenever a meaningful behavior change ships. Logged as the first row of every
# report (and printed in the startup banner) so a saved CSV alone tells you whether a given
# run had a feature - no need to diff the .ps1 file against what's currently in this folder.
$Script:ScriptVersion = "2026-07-10.2 (adds -CloudOnly; license removal default-on, dynamic-group skip, sync recheck)"
#endregion

if (-not $SharedMailboxOU) { $SharedMailboxOU = $Script:DefaultSharedMailboxOU }

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[Object]

function Add-Result {
    param($Stage, $Item, $Action, $Status, $Detail = "")
    $results.Add([PSCustomObject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Stage     = $Stage
        Item      = $Item
        Action    = $Action
        Status    = $Status
        Detail    = $Detail
    })
}

Add-Result "Script" "Version" "n/a" "Info" $Script:ScriptVersion

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
$transcriptFile = Join-Path $ReportPath "$SamAccountName`_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $transcriptFile -Append | Out-Null

Write-Host ("=== Offboarding $SamAccountName" + $(if ($CloudOnly) { " (cloud-only - AD steps assumed already done)" }) + "  |  script v$Script:ScriptVersion ===") -ForegroundColor Cyan

#region 1. Load / verify modules (installs on demand instead of assuming they're present)
Ensure-Module -Name 'ActiveDirectory' -IsWindowsFeature -ManualInstallHint (
    "Windows 10/11: Settings > Optional Features > Add a feature > 'RSAT: Active Directory " +
    "Domain Services and Lightweight Directory Tools' (or run, as admin: " +
    "Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0). " +
    "Windows Server: Install-WindowsFeature RSAT-AD-PowerShell."
)
Ensure-Module -Name 'ExchangeOnlineManagement' -ManualInstallHint "Install-Module ExchangeOnlineManagement -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Users' -ManualInstallHint "Install-Module Microsoft.Graph.Users -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Groups' -ManualInstallHint "Install-Module Microsoft.Graph.Groups -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Identity.DirectoryManagement' -ManualInstallHint "Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Identity.SignIns' -ManualInstallHint "Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser"
#endregion

#region 1b. Validate configuration now that ActiveDirectory is loaded
if (-not $SharedMailboxOU -or $SharedMailboxOU -like "*CHANGE-ME*") {
    Stop-Transcript | Out-Null
    throw ("-SharedMailboxOU was not provided and the default in section 0 is still the placeholder. " +
           "Either pass -SharedMailboxOU 'OU=...,DC=...,DC=...' or edit `$Script:DefaultSharedMailboxOU " +
           "near the top of this script. See .NOTES ('Finding your environment-specific values') for how " +
           "to find your OU's distinguished name.")
}
if (-not (Get-ADOrganizationalUnit -Identity $SharedMailboxOU -ErrorAction SilentlyContinue)) {
    Stop-Transcript | Out-Null
    throw ("Could not find an OU with distinguished name '$SharedMailboxOU' in this domain. Double-check " +
           "it with: Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName")
}
#endregion

#region 2. Look up AD user
try {
    $adUser = Get-ADUser -Identity $SamAccountName -Properties MemberOf, PrimaryGroupID, UserPrincipalName, mail
}
catch {
    Add-Result "Lookup" $SamAccountName "Get-ADUser" "Failed" $_.Exception.Message
    Stop-Transcript | Out-Null
    throw "Could not find AD user '$SamAccountName': $_"
}
$upn = $adUser.UserPrincipalName
Write-Host "Found AD user: $($adUser.DistinguishedName)"
Write-Host "UPN: $upn"
#endregion

#region 3. Disable AD account
if ($CloudOnly) {
    Add-Result "AD" $SamAccountName "Disable-ADAccount" "Skipped" "CloudOnly specified - AD account assumed already disabled"
}
elseif ($PSCmdlet.ShouldProcess($SamAccountName, "Disable-ADAccount")) {
    try {
        Disable-ADAccount -Identity $adUser.DistinguishedName
        Add-Result "AD" $SamAccountName "Disable-ADAccount" "Success"
    }
    catch {
        Add-Result "AD" $SamAccountName "Disable-ADAccount" "Failed" $_.Exception.Message
    }
}
#endregion

#region 4. Move to shared-mailbox / disabled-users OU
if ($CloudOnly) {
    Add-Result "AD" $SamAccountName "Move-ADObject" "Skipped" "CloudOnly specified - AD object assumed already moved"
}
elseif ($PSCmdlet.ShouldProcess($SamAccountName, "Move-ADObject to $SharedMailboxOU")) {
    try {
        Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $SharedMailboxOU
        Add-Result "AD" $SamAccountName "Move-ADObject" "Success" $SharedMailboxOU
        # Refresh the AD object reference - DN changed
        $adUser = Get-ADUser -Identity $SamAccountName -Properties MemberOf, PrimaryGroupID, UserPrincipalName, mail
    }
    catch {
        Add-Result "AD" $SamAccountName "Move-ADObject" "Failed" $_.Exception.Message
    }
}
#endregion

#region 5. Convert mailbox to shared (Exchange Online)
if (-not $SkipMailboxConversion) {
    try {
        if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
            Connect-ExchangeOnline -ShowBanner:$false
        }
        if ($PSCmdlet.ShouldProcess($upn, "Set-Mailbox -Type Shared")) {
            $mbx = Get-Mailbox -Identity $upn -ErrorAction SilentlyContinue
            if ($mbx) {
                Set-Mailbox -Identity $upn -Type Shared
                Add-Result "Exchange" $upn "Convert to Shared Mailbox" "Success"
            }
            else {
                Add-Result "Exchange" $upn "Convert to Shared Mailbox" "Skipped" "No mailbox found for user"
            }
        }
    }
    catch {
        Add-Result "Exchange" $upn "Convert to Shared Mailbox" "Failed" $_.Exception.Message
    }
}
else {
    Add-Result "Exchange" $upn "Convert to Shared Mailbox" "Skipped" "SkipMailboxConversion specified"
}
#endregion

#region 5b. Remove assigned Entra ID licenses (default on; opt out via -SkipLicenseRemoval)
# Runs after mailbox conversion above on purpose - pulling a license out from under a
# mailbox that's still mid-conversion can leave it in a bad state. Shared mailboxes
# themselves don't need a license, so this is safe to do once step 5 has completed.
if (-not $SkipLicenseRemoval) {
    Write-Host "`n--- License removal ---" -ForegroundColor Cyan
    try {
        Ensure-Module -Name 'Microsoft.Graph.Users.Actions' -ManualInstallHint "Install-Module Microsoft.Graph.Users.Actions -Scope CurrentUser"
        if (-not (Get-MgContext)) {
            Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "GroupMember.ReadWrite.All", "Directory.Read.All" -NoWelcome
        }
        $mgUserForLicense = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property Id, UserPrincipalName
        if (-not $mgUserForLicense) {
            Add-Result "Entra-Licenses" $upn "Remove licenses" "Failed" "User not found in Entra ID - hybrid sync may not have completed yet"
        }
        else {
            $licenseDetails = Get-MgUserLicenseDetail -UserId $mgUserForLicense.Id
            if (-not $licenseDetails -or @($licenseDetails).Count -eq 0) {
                Add-Result "Entra-Licenses" $upn "Remove licenses" "Skipped" "No licenses currently assigned"
            }
            else {
                $skuIds   = @($licenseDetails | ForEach-Object { $_.SkuId })
                $skuNames = ($licenseDetails | ForEach-Object { $_.SkuPartNumber }) -join ", "
                if ($PSCmdlet.ShouldProcess($upn, "Remove license(s): $skuNames")) {
                    try {
                        Set-MgUserLicense -UserId $mgUserForLicense.Id -AddLicenses @() -RemoveLicenses $skuIds | Out-Null
                        Add-Result "Entra-Licenses" $upn "Set-MgUserLicense (remove)" "Success" $skuNames
                    }
                    catch {
                        Add-Result "Entra-Licenses" $upn "Set-MgUserLicense (remove)" "Failed" $_.Exception.Message
                    }
                }
            }
        }
    }
    catch {
        Add-Result "Entra-Licenses" $upn "License removal" "Failed" $_.Exception.Message
    }
}
else {
    Add-Result "Entra-Licenses" $upn "Remove licenses" "Skipped" "SkipLicenseRemoval specified"
}
#endregion

#region 6. Remove from all local AD groups
Write-Host "`n--- Local AD group cleanup ---" -ForegroundColor Cyan
if ($CloudOnly) {
    Add-Result "AD-Groups" "n/a" "Remove-ADGroupMember" "Skipped" "CloudOnly specified - AD groups assumed already removed"
}
else {
    try {
        $adGroups = Get-ADPrincipalGroupMembership -Identity $adUser.DistinguishedName
    }
    catch {
        $adGroups = @()
        Add-Result "AD-Groups" $SamAccountName "Get-ADPrincipalGroupMembership" "Failed" $_.Exception.Message
    }

    # Primary group (usually "Domain Users") can't be removed via Remove-ADGroupMember - it has
    # to be reassigned via PrimaryGroupID first. Build its SID from the user's own SID (domain
    # portion) + PrimaryGroupID (the RID) so we can recognize and skip it below.
    $primaryGroupSID = $adUser.SID.Value.Substring(0, $adUser.SID.Value.LastIndexOf('-')) + "-" + $adUser.PrimaryGroupID

    foreach ($grp in $adGroups) {
        if ($grp.SID.Value -eq $primaryGroupSID) {
            Add-Result "AD-Groups" $grp.Name "Remove-ADGroupMember" "Skipped" "Primary group - reassign PrimaryGroupID first if this must change"
            continue
        }
        if ($PSCmdlet.ShouldProcess($grp.Name, "Remove-ADGroupMember ($SamAccountName)")) {
            try {
                Remove-ADGroupMember -Identity $grp.DistinguishedName -Members $adUser.DistinguishedName -Confirm:$false
                Add-Result "AD-Groups" $grp.Name "Remove-ADGroupMember" "Success"
            }
            catch {
                Add-Result "AD-Groups" $grp.Name "Remove-ADGroupMember" "Failed" $_.Exception.Message
            }
        }
    }
}
#endregion

#region 7. Trigger / wait for Entra Connect delta sync
if (-not $SkipEntraSyncWait -and $EntraConnectServer) {
    Write-Host "`n--- Triggering Entra Connect delta sync on $EntraConnectServer ---" -ForegroundColor Cyan
    try {
        Invoke-Command -ComputerName $EntraConnectServer -ScriptBlock {
            Import-Module ADSync
            Start-ADSyncSyncCycle -PolicyType Delta
        } -ErrorAction Stop
        Add-Result "Sync" $EntraConnectServer "Start-ADSyncSyncCycle Delta" "Triggered"

        # Best-effort wait: sync cycles usually complete in under a couple minutes.
        # There is no reliable single cmdlet to "await completion" remotely, so we
        # poll the sync scheduler state on the Connect server.
        $elapsed = 0
        do {
            Start-Sleep -Seconds 15
            $elapsed += 15
            $syncing = Invoke-Command -ComputerName $EntraConnectServer -ScriptBlock {
                (Get-ADSyncScheduler).SyncCycleInProgress
            }
        } while ($syncing -and $elapsed -lt $SyncWaitTimeoutSeconds)

        if ($syncing) {
            Add-Result "Sync" $EntraConnectServer "Wait for sync completion" "TimedOut" "Exceeded $SyncWaitTimeoutSeconds s; cloud group checks below may be stale"
        }
        else {
            Add-Result "Sync" $EntraConnectServer "Wait for sync completion" "Success" "Completed in ~${elapsed}s"
        }
    }
    catch {
        Add-Result "Sync" $EntraConnectServer "Start-ADSyncSyncCycle Delta" "Failed" $_.Exception.Message
        Write-Warning "Could not trigger/verify Entra Connect sync. Cloud-side group checks below may reflect stale (pre-removal) AD data. Re-run cloud cleanup after sync completes if warnings appear."
    }
}
else {
    Add-Result "Sync" "n/a" "Entra Connect delta sync" "Skipped" "SkipEntraSyncWait set or no -EntraConnectServer provided"
}
#endregion

#region 8. Connect to Graph and clean up cloud-only groups
Write-Host "`n--- Cloud (Entra ID) group cleanup ---" -ForegroundColor Cyan
try {
    if (-not (Get-MgContext)) {
        Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "GroupMember.ReadWrite.All", "Directory.Read.All" -NoWelcome
    }

    $mgUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property Id, UserPrincipalName
    if (-not $mgUser) {
        Add-Result "Entra" $upn "Get-MgUser" "Failed" "User not found in Entra ID - hybrid sync may not have completed yet"
    }
    else {
        $memberOf = Get-MgUserMemberOf -UserId $mgUser.Id -All
        $syncedGroupsToRecheck = New-Object System.Collections.Generic.List[Object]

        foreach ($m in $memberOf) {
            # memberOf can include directory roles too - only act on actual groups
            if ($m.AdditionalProperties['@odata.type'] -ne '#microsoft.graph.group') { continue }

            $groupId       = $m.Id
            $groupDetail   = Get-MgGroup -GroupId $groupId -Property Id, DisplayName, OnPremisesSyncEnabled, MailEnabled, SecurityEnabled, GroupTypes
            $groupName     = $groupDetail.DisplayName
            $isSynced      = [bool]$groupDetail.OnPremisesSyncEnabled
            $isMailEnabled = [bool]$groupDetail.MailEnabled
            $isM365Group   = $groupDetail.GroupTypes -contains "Unified"
            $isDynamic     = $groupDetail.GroupTypes -contains "DynamicMembership"

            if ($isSynced) {
                # Should have been handled in the AD step above. Flag if it's still showing,
                # and queue it for a second-pass re-check below - Entra Connect sync and the
                # directory replication behind it can both lag a bit past this point.
                Add-Result "Entra-Groups" $groupName "Verify sync-removed" "Warning" "Synced group still shows as member post-sync - check AD removal / re-run sync"
                $syncedGroupsToRecheck.Add([PSCustomObject]@{ GroupId = $groupId; GroupName = $groupName })
                continue
            }

            if ($isDynamic) {
                # Dynamic groups compute membership from a rule - no admin role or API call
                # can manually add/remove a member, so don't waste a call / throw a 403.
                Add-Result "Entra-Groups" $groupName "Skip (dynamic group)" "Skipped" "Membership is rule-based and can't be manually removed. If this user shouldn't match it, adjust the group's dynamic membership rule instead (e.g. exclude disabled accounts)."
                continue
            }

            if ($PSCmdlet.ShouldProcess($groupName, "Remove cloud group membership ($upn)")) {
                if ($isMailEnabled -and -not $isM365Group) {
                    # Plain mail-enabled security groups / distribution lists: Graph member
                    # removal is inconsistent for these, use Exchange Online instead.
                    try {
                        if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
                            Connect-ExchangeOnline -ShowBanner:$false
                        }
                        Remove-DistributionGroupMember -Identity $groupName -Member $upn -Confirm:$false -BypassSecurityGroupManagerCheck
                        Add-Result "Entra-Groups" $groupName "Remove-DistributionGroupMember (EXO)" "Success"
                    }
                    catch {
                        Add-Result "Entra-Groups" $groupName "Remove-DistributionGroupMember (EXO)" "Failed" $_.Exception.Message
                    }
                }
                else {
                    # Cloud-only security group or M365 group - Graph handles this directly.
                    try {
                        Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $mgUser.Id
                        Add-Result "Entra-Groups" $groupName "Remove-MgGroupMemberByRef" "Success"
                    }
                    catch {
                        Add-Result "Entra-Groups" $groupName "Remove-MgGroupMemberByRef" "Failed" $_.Exception.Message
                    }
                }
            }
        }

        #region 8b. Second-pass re-check of synced groups flagged above
        # A "Verify sync-removed" warning above just means Entra still showed the group at
        # the moment we checked - that can be true even after a real sync finished, because
        # Entra Connect's own replication into Entra ID/Graph can lag a bit further. This
        # waits, then re-checks specifically those groups so the report shows whether they
        # actually cleared instead of leaving a stale-looking warning.
        if ($syncedGroupsToRecheck.Count -gt 0) {
            if ($SkipSyncRecheck) {
                Add-Result "Entra-Groups" "n/a" "Verify sync-removed recheck" "Skipped" "SkipSyncRecheck specified - $($syncedGroupsToRecheck.Count) group(s) left as initially flagged above"
            }
            else {
                Write-Host "`n--- Re-checking $($syncedGroupsToRecheck.Count) synced group(s) after ${SyncRecheckWaitSeconds}s ---" -ForegroundColor Cyan
                Start-Sleep -Seconds $SyncRecheckWaitSeconds
                try {
                    $freshMemberOf  = Get-MgUserMemberOf -UserId $mgUser.Id -All
                    $freshGroupIds  = @($freshMemberOf | Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' } | Select-Object -ExpandProperty Id)
                    foreach ($g in $syncedGroupsToRecheck) {
                        if ($freshGroupIds -contains $g.GroupId) {
                            Add-Result "Entra-Groups" $g.GroupName "Verify sync-removed (recheck)" "Warning" "Still a member after ${SyncRecheckWaitSeconds}s wait - verify AD removal completed and check Entra Connect sync health"
                        }
                        else {
                            Add-Result "Entra-Groups" $g.GroupName "Verify sync-removed (recheck)" "Success" "Cleared after ${SyncRecheckWaitSeconds}s wait - no longer a member"
                        }
                    }
                }
                catch {
                    Add-Result "Entra-Groups" "n/a" "Verify sync-removed recheck" "Failed" $_.Exception.Message
                }
            }
        }
        #endregion

        #region 9. Revoke sessions + block cloud sign-in
        if ($PSCmdlet.ShouldProcess($upn, "Revoke sign-in sessions & block cloud sign-in")) {
            try {
                Revoke-MgUserSignInSession -UserId $mgUser.Id | Out-Null
                Add-Result "Entra" $upn "Revoke-MgUserSignInSession" "Success"
            }
            catch {
                Add-Result "Entra" $upn "Revoke-MgUserSignInSession" "Failed" $_.Exception.Message
            }
            try {
                Update-MgUser -UserId $mgUser.Id -AccountEnabled:$false
                Add-Result "Entra" $upn "Update-MgUser AccountEnabled=false" "Success"
            }
            catch {
                Add-Result "Entra" $upn "Update-MgUser AccountEnabled=false" "Failed" $_.Exception.Message
            }
        }
        #endregion
    }
}
catch {
    Add-Result "Entra" $upn "Graph cleanup" "Failed" $_.Exception.Message
}
#endregion

#region 10. Report
$reportFile = Join-Path $ReportPath "$SamAccountName`_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $reportFile -NoTypeInformation

Write-Host "`n=== Summary for $SamAccountName ===" -ForegroundColor Cyan
$results | Format-Table Stage, Item, Action, Status -AutoSize

$failures = $results | Where-Object { $_.Status -in @('Failed', 'Warning', 'TimedOut') }
if ($failures) {
    Write-Warning "$($failures.Count) item(s) need manual review - see $reportFile"
}
else {
    Write-Host "All steps completed cleanly. Report: $reportFile" -ForegroundColor Green
}

Stop-Transcript | Out-Null
#endregion
