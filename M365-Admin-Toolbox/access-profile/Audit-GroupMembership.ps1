#Requires -Version 5.1
<#
.SYNOPSIS
    Audits on-prem AD and cloud-only Entra ID Security and Distribution
    groups for two things: members whose account is disabled/inactive, and
    groups that have zero direct members at all.

.DESCRIPTION
    THIS IS THE VENDOR-NEUTRAL VARIANT. Where this script has environment
    defaults - OUs, UPN suffix, Entra Connect server - they are read from
    environment.psd1 beside it. Copy environment.example.psd1 and fill it in
    before first use. Every value there is a default; the equivalent
    parameter always wins.

    Two independent findings, reported separately:
      1. STALE MEMBERSHIP - a group has at least one direct member whose
         account is disabled (AD: Enabled = $false; Entra: AccountEnabled =
         $false). Every stale member found is listed individually per group.
      2. EMPTY GROUP - a group has zero direct members of any kind. These
         are candidates for cleanup/decommission, but this script NEVER
         deletes a group automatically under any switch - that's a judgment
         call (seasonal groups, groups pre-provisioned for a future project,
         etc.) that always needs a human decision.

    This script does NOT audit dynamic-membership groups - those are
    covered by the companion Audit-DynamicGroupInactiveFilter
    script, which checks whether a dynamic group's *rule* already excludes
    disabled accounts (e.g. your "All Entra Company Users" group). This
    script instead checks actual, assigned group membership.

    Covers, per source:
      - On-prem AD: every security and distribution group (Get-ADGroup
        covers both - GroupCategory is always one or the other), optionally
        scoped to -ADSearchBase.
      - Entra ID: cloud-only groups only (OnPremisesSyncEnabled is
        $false/$null) - security groups, mail-enabled security groups,
        distribution lists, and Microsoft 365 Groups - excluding dynamic-
        membership groups (like your AP-* Autopilot groups and "All
        Entra Company Users"/"All Entra Company Win PCs", which are dynamic and
        therefore out of scope here). Synced groups are evaluated once, on
        the AD side only, so the same group/membership isn't
        double-reported.

    IMPORTANT - ONLY DIRECT MEMBERS ARE EVALUATED. Nested group membership
    is not expanded/recursed. A group whose only members are other groups
    (no direct user members) is reported as EMPTY GROUP even though those
    nested groups may have members of their own - the Detail field on every
    empty-group finding calls this out explicitly so it isn't misread as a
    true zero-membership chain.

    This script is READ-ONLY by default - it only reports. Pass
    -RemoveInactiveMembers to interactively remove flagged stale members
    from their group (confirmed individually, supports -WhatIf). Empty
    groups are never acted on by this script under any switch.

.PARAMETER ADSearchBase
    Distinguished name to scope the on-prem AD portion of the audit to a
    specific OU. Omit to audit every Security/Distribution group in the
    domain.

.PARAMETER RemoveInactiveMembers
    Interactively remove flagged disabled/inactive members from their
    group. Each removal is confirmed individually (y/N) and supports
    -WhatIf. Off by default - report-only is the safe default. Never
    deletes a group, even an empty one.

.PARAMETER ReportPath
    Folder to write the CSV report and transcript log to. Defaults to a
    a Reports\GroupMembershipAudits subfolder inside this script's own package
    folder (resolved via $PSScriptRoot, so the package is portable) - not a
    relative ".\..." path, so reports always land in the same findable spot
    no matter what directory PowerShell happens to be in when you run this
    (e.g. C:\Windows\System32, which is where this ends up if launched from
    a shortcut/Run box without changing directory first).

.PARAMETER AutoInstallMissingModules
    If a required PSGallery module isn't installed, install it
    automatically instead of prompting. The ActiveDirectory module (RSAT)
    can never be auto-installed this way.

.PARAMETER WhatIf
    Preview -RemoveInactiveMembers actions without making them. Has no
    effect on the audit/report portion, which never makes changes
    regardless.

.EXAMPLE
    .\Audit-GroupMembership.ps1
    Report-only pass over every AD + cloud Security/Distribution group.

.EXAMPLE
    .\Audit-GroupMembership.ps1 -ADSearchBase "OU=Groups,OU=Company Users,DC=contoso,DC=local"
    Scope the AD portion of the audit to a specific OU.

.EXAMPLE
    .\Audit-GroupMembership.ps1 -RemoveInactiveMembers -WhatIf
    Preview what removing stale members would do, without changing anything.

.EXAMPLE
    .\Audit-GroupMembership.ps1 -RemoveInactiveMembers
    Audit and interactively remove every stale member found (confirmed one
    at a time). Empty groups are still only reported, never deleted.

.NOTES
    Required modules  : ActiveDirectory, Microsoft.Graph.Users,
                         Microsoft.Graph.Groups,
                         Microsoft.Graph.Identity.DirectoryManagement
    Required Graph scopes (delegated or app-only) :
                         User.Read.All, Group.Read.All, Directory.Read.All,
                         GroupMember.ReadWrite.All (only needed if
                         -RemoveInactiveMembers is used)

    Mail-enabled cloud group member removal (Distribution Lists /
    mail-enabled security groups) requires ExchangeOnlineManagement - it is
    only checked/imported/connected if -RemoveInactiveMembers actually
    needs to act on one of those group types.

    Run this from an admin workstation with the ActiveDirectory RSAT module
    installed, or from a domain controller. The Graph connection happens
    over the internet regardless of where the script runs.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$ADSearchBase,

    [switch]$RemoveInactiveMembers,

    [string]$ReportPath,

    [switch]$AutoInstallMissingModules
)

# --- Portable path resolution ----------------------------------------------------------
# Resolve output locations against THIS SCRIPT'S OWN FOLDER so the whole package works
# unchanged from a flash drive, a UNC share, or a local disk. $PSScriptRoot is used
# deliberately instead of '.\' or $PWD, which resolve against whatever directory PowerShell
# happened to start in (C:\Windows\System32 when launched from a shortcut or the Run box).
$Script:PackageRoot = $PSScriptRoot
if (-not $Script:PackageRoot) { $Script:PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Script:PackageRoot) { $Script:PackageRoot = (Get-Location).Path }
if (-not $ReportPath) { $ReportPath = Join-Path $Script:PackageRoot 'Reports\GroupMembershipAudits' }
# ---------------------------------------------------------------------------------------


# Bump on any behaviour change; logged with each run so a saved report maps to a build.
$Script:ScriptVersion = "2026-08-06.1 (Exchange connection probe no longer throws NullReference on a fresh session)"

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[Object]

function Add-Result {
    param($Source, $GroupName, $Category, $Detail, $Action = "Audit", $Status = "Flagged")
    $results.Add([PSCustomObject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Source    = $Source
        GroupName = $GroupName
        Category  = $Category
        Action    = $Action
        Status    = $Status
        Detail    = $Detail
    })
}

# Ensures a required module is available, importing it if present, offering to install it
# if it's missing and comes from PSGallery, or explaining how to get it if it doesn't
# (currently only ActiveDirectory/RSAT, which is a Windows feature, not a gallery module).
# Get-ConnectionInformation calls Get-ConnectionContext internally, and with no active
# session some ExchangeOnlineManagement versions throw a NullReferenceException rather than
# returning null. -ErrorAction SilentlyContinue does NOT suppress that, because it is a
# terminating exception raised inside the cmdlet, not an error record. Unhandled, it aborts
# the enclosing try block - so a run with no prior Exchange session silently skipped the
# mailbox conversion entirely. Any failure here means "not connected".
function Test-ExoConnected {
    try   { return [bool](Get-ConnectionInformation -ErrorAction Stop) }
    catch { return $false }
}

function Ensure-Module {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ManualInstallHint,
        [switch]$IsWindowsFeature
    )
    # Already imported in this session? Don't re-import. Re-importing a Microsoft.Graph
    # submodule can trip the SDK's assembly-version conflict, and there's nothing to gain.
    if (Get-Module -Name $Name) { return }

    if (Get-Module -ListAvailable -Name $Name) {
        try {
            Import-Module -Name $Name -ErrorAction Stop
        }
        catch {
            # "Assembly with same name is already loaded" is the Microsoft.Graph SDK's
            # signature failure: .NET cannot host two versions of the same assembly in one
            # session, so once one Graph submodule has pulled in a given
            # Microsoft.Graph.Authentication, any submodule pinned to a different version
            # cannot load. Nothing the script does can unload it - the session is already
            # committed. The raw error names an assembly and a version and explains none of
            # this, so translate it.
            if ($_.Exception.Message -match 'Assembly with same name is already loaded' -or
                $_.Exception.Message -match 'Could not load file or assembly .*Microsoft\.Graph') {

                # Two different root causes produce the same exception, and they need
                # different fixes - so work out which one this is instead of guessing.
                #   Stale session   : modules loaded here are at MIXED versions, because
                #                     earlier Graph work in this session pinned one.
                #   Bad install     : loaded versions all AGREE, so the session is clean and
                #                     the module being imported is installed at a version
                #                     that wants a different Authentication assembly.
                $loadedMods  = @(Get-Module Microsoft.Graph*)
                $loadedList  = @($loadedMods | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', '
                $loadedVers  = @($loadedMods | Select-Object -ExpandProperty Version -Unique)
                $sessionMixed = $loadedVers.Count -gt 1

                # Installed versions of the module that just failed - this is what names the culprit.
                $installed = @()
                try {
                    $installed = @(Get-Module -ListAvailable -Name $Name |
                                   Select-Object -ExpandProperty Version |
                                   Sort-Object -Unique | ForEach-Object { [string]$_ })
                }
                catch { }

                $msg = "Microsoft Graph assembly conflict while importing '$Name'.`n`n"
                $msg += "  $($_.Exception.Message)`n`n"
                $msg += "One session cannot host two versions of the same assembly, so once a Graph submodule "
                $msg += "has fixed the Microsoft.Graph.Authentication version, any submodule needing a different "
                $msg += "one cannot load.`n`n"
                $msg += "  Loaded in this session : $(if ($loadedList) { $loadedList } else { '(none)' })`n"
                $msg += "  '$Name' installed at   : $(if ($installed.Count) { $installed -join ', ' } else { '(unknown)' })`n`n"

                if ($sessionMixed) {
                    $msg += "DIAGNOSIS: the loaded modules are at MIXED versions, so this session was already "
                    $msg += "committed by earlier Graph work.`n"
                    $msg += "FIX: run this script in a fresh PowerShell session, before any other Graph work.`n"
                }
                else {
                    $msg += "DIAGNOSIS: the loaded modules all agree on one version, so the session is clean - "
                    $msg += "'$Name' is INSTALLED at a version that doesn't match the rest. A fresh session will "
                    $msg += "NOT help.`n`n"
                    $msg += "FIX: align the installed versions. Check them all:`n"
                    $msg += "  Get-Module Microsoft.Graph* -ListAvailable | Select-Object Name,Version | Sort-Object Name,Version`n`n"
                    $msg += "then install the odd one out at the version the others are on, e.g.`n"
                    $msg += "  Install-Module $Name -RequiredVersion $(if ($loadedVers.Count -eq 1) { $loadedVers[0] } else { '<version>' }) -Scope CurrentUser -Force -AllowClobber`n`n"
                    $msg += "Reopen PowerShell afterwards - the bad assembly stays loaded until you do."
                }
                throw $msg
            }
            throw
        }
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
$transcriptFile = Join-Path $ReportPath "GroupMembershipAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $transcriptFile -Append | Out-Null

Write-Host "=== Security & Distribution Group Membership Audit ===" -ForegroundColor Cyan
Write-Host "Reports will be saved to: $ReportPath" -ForegroundColor DarkCyan

#region 1. Load / verify modules
Ensure-Module -Name 'ActiveDirectory' -IsWindowsFeature -ManualInstallHint (
    "Windows 10/11: Settings > Optional Features > Add a feature > 'RSAT: Active Directory " +
    "Domain Services and Lightweight Directory Tools' (or run, as admin: " +
    "Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0). " +
    "Windows Server: Install-WindowsFeature RSAT-AD-PowerShell."
)
Ensure-Module -Name 'Microsoft.Graph.Users' -ManualInstallHint "Install-Module Microsoft.Graph.Users -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Groups' -ManualInstallHint "Install-Module Microsoft.Graph.Groups -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Identity.DirectoryManagement' -ManualInstallHint "Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser"
#endregion

#region 2. Connect to Graph
$requiredScopes = @("User.Read.All", "Group.Read.All", "Directory.Read.All")
if ($RemoveInactiveMembers) { $requiredScopes += "GroupMember.ReadWrite.All" }

if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes $requiredScopes -NoWelcome
}
else {
    $currentScopes = (Get-MgContext).Scopes
    $missing = $requiredScopes | Where-Object { $_ -notin $currentScopes }
    if ($missing) {
        Write-Warning "Current Graph session is missing scope(s): $($missing -join ', '). Reconnecting."
        Disconnect-MgGraph | Out-Null
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    }
}
#endregion

#region 3. On-prem AD groups
Write-Host "`n--- On-prem AD Security & Distribution groups ---" -ForegroundColor Cyan
$adGroupParams = @{ Filter = '*'; Properties = @('GroupCategory', 'mail', 'Description') }
if ($ADSearchBase) {
    if (-not (Get-ADOrganizationalUnit -Identity $ADSearchBase -ErrorAction SilentlyContinue)) {
        Stop-Transcript | Out-Null
        throw ("Could not find an OU with distinguished name '$ADSearchBase' in this domain. Double-check " +
               "it with: Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName")
    }
    $adGroupParams.SearchBase = $ADSearchBase
}
$adGroups = Get-ADGroup @adGroupParams
Write-Host "Found $($adGroups.Count) AD group(s) to check."

foreach ($grp in $adGroups) {
    $members = @(Get-ADGroupMember -Identity $grp.DistinguishedName -ErrorAction SilentlyContinue)

    if ($members.Count -eq 0) {
        Add-Result "AD" $grp.Name "EmptyGroup" "Group has zero direct members ($($grp.GroupCategory))"
        continue
    }

    $nestedGroupCount = @($members | Where-Object { $_.objectClass -eq 'group' }).Count
    $userMembers      = @($members | Where-Object { $_.objectClass -eq 'user' })

    if ($userMembers.Count -eq 0 -and $nestedGroupCount -gt 0) {
        Add-Result "AD" $grp.Name "EmptyGroup" "0 direct user members, but $nestedGroupCount nested group member(s) not expanded by this audit - not necessarily truly empty"
    }

    foreach ($member in $userMembers) {
        try {
            $adUser = Get-ADUser -Identity $member.DistinguishedName -Properties Enabled -ErrorAction Stop
        }
        catch {
            Add-Result "AD" $grp.Name "StaleMembership" "Could not look up member $($member.SamAccountName): $($_.Exception.Message)" "Audit" "Failed"
            continue
        }
        if (-not $adUser.Enabled) {
            Add-Result "AD" $grp.Name "StaleMembership" "Member $($adUser.SamAccountName) is disabled in AD"
            if ($RemoveInactiveMembers -and $PSCmdlet.ShouldProcess("$($adUser.SamAccountName) / $($grp.Name)", "Remove-ADGroupMember")) {
                $confirm = Read-Host "  Remove disabled member '$($adUser.SamAccountName)' from AD group '$($grp.Name)'? (y/N)"
                if ($confirm -eq 'y') {
                    try {
                        Remove-ADGroupMember -Identity $grp.DistinguishedName -Members $adUser.DistinguishedName -Confirm:$false
                        Add-Result "AD" $grp.Name "StaleMembership" "Removed $($adUser.SamAccountName)" "Remediate" "Fixed"
                    }
                    catch {
                        Add-Result "AD" $grp.Name "StaleMembership" "Failed to remove $($adUser.SamAccountName): $($_.Exception.Message)" "Remediate" "Failed"
                    }
                }
                else {
                    Add-Result "AD" $grp.Name "StaleMembership" "Skipped by operator" "Remediate" "Skipped"
                }
            }
        }
    }
}
#endregion

#region 4. Cloud-only Entra ID groups (non-synced, non-dynamic)
Write-Host "`n--- Cloud-only Entra ID Security & Distribution groups ---" -ForegroundColor Cyan
$entraGroups = Get-MgGroup -All -Property Id, DisplayName, GroupTypes, OnPremisesSyncEnabled, MailEnabled, SecurityEnabled |
    Where-Object {
        (-not ($_.GroupTypes -contains "DynamicMembership")) -and
        (-not [bool]$_.OnPremisesSyncEnabled)
    }
Write-Host "Found $($entraGroups.Count) cloud-only, non-dynamic group(s) to check (synced groups already covered on the AD side above; dynamic groups like AP-* and 'All Entra Company Users' are out of scope for this script)."

foreach ($grp in $entraGroups) {
    $isM365Group   = $grp.GroupTypes -contains "Unified"
    $isMailEnabled = [bool]$grp.MailEnabled
    $groupTypeLabel = if ($isM365Group) { "Microsoft 365 Group" } elseif ($isMailEnabled) { "Mail-enabled/Distribution" } else { "Security" }

    $members = @(Get-MgGroupMember -GroupId $grp.Id -All)

    if ($members.Count -eq 0) {
        Add-Result "Entra" $grp.DisplayName "EmptyGroup" "Group has zero direct members ($groupTypeLabel)"
        continue
    }

    $nestedGroupCount = @($members | Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' }).Count
    $userMembers      = @($members | Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.user' })

    if ($userMembers.Count -eq 0 -and $nestedGroupCount -gt 0) {
        Add-Result "Entra" $grp.DisplayName "EmptyGroup" "0 direct user members, but $nestedGroupCount nested group member(s) not expanded by this audit - not necessarily truly empty"
    }

    foreach ($member in $userMembers) {
        try {
            $mgUser = Get-MgUser -UserId $member.Id -Property Id, UserPrincipalName, AccountEnabled -ErrorAction Stop
        }
        catch {
            Add-Result "Entra" $grp.DisplayName "StaleMembership" "Could not look up member id $($member.Id): $($_.Exception.Message)" "Audit" "Failed"
            continue
        }
        if (-not $mgUser.AccountEnabled) {
            Add-Result "Entra" $grp.DisplayName "StaleMembership" "Member $($mgUser.UserPrincipalName) is disabled (AccountEnabled = false)"
            if ($RemoveInactiveMembers -and $PSCmdlet.ShouldProcess("$($mgUser.UserPrincipalName) / $($grp.DisplayName)", "Remove cloud group membership")) {
                $confirm = Read-Host "  Remove disabled member '$($mgUser.UserPrincipalName)' from group '$($grp.DisplayName)'? (y/N)"
                if ($confirm -eq 'y') {
                    try {
                        if ($isMailEnabled -and -not $isM365Group) {
                            Ensure-Module -Name 'ExchangeOnlineManagement' -ManualInstallHint "Install-Module ExchangeOnlineManagement -Scope CurrentUser"
                            if (-not (Test-ExoConnected)) {
                                Connect-ExchangeOnline -ShowBanner:$false
                            }
                            Remove-DistributionGroupMember -Identity $grp.DisplayName -Member $mgUser.UserPrincipalName -Confirm:$false -BypassSecurityGroupManagerCheck
                        }
                        else {
                            Remove-MgGroupMemberByRef -GroupId $grp.Id -DirectoryObjectId $mgUser.Id
                        }
                        Add-Result "Entra" $grp.DisplayName "StaleMembership" "Removed $($mgUser.UserPrincipalName)" "Remediate" "Fixed"
                    }
                    catch {
                        Add-Result "Entra" $grp.DisplayName "StaleMembership" "Failed to remove $($mgUser.UserPrincipalName): $($_.Exception.Message)" "Remediate" "Failed"
                    }
                }
                else {
                    Add-Result "Entra" $grp.DisplayName "StaleMembership" "Skipped by operator" "Remediate" "Skipped"
                }
            }
        }
    }
}
#endregion

#region 5. Report
$reportFile = Join-Path $ReportPath "GroupMembershipAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $reportFile -NoTypeInformation

$staleGroups = $results | Where-Object { $_.Category -eq 'StaleMembership' -and $_.Action -eq 'Audit' } | Select-Object -ExpandProperty GroupName -Unique
$emptyGroups = $results | Where-Object { $_.Category -eq 'EmptyGroup' }

Write-Host "`n=== Audit summary ===" -ForegroundColor Cyan
Write-Host "AD groups checked    : $($adGroups.Count)"
Write-Host "Entra groups checked : $($entraGroups.Count)"
Write-Host ""
Write-Host "Groups with stale (disabled) members : $($staleGroups.Count)" -ForegroundColor $(if ($staleGroups.Count -gt 0) { "Yellow" } else { "Green" })
if ($staleGroups.Count -gt 0) { Write-Host "  $($staleGroups -join ', ')" -ForegroundColor Yellow }
Write-Host ""
Write-Host "Empty groups (zero direct members) : $($emptyGroups.Count)" -ForegroundColor $(if ($emptyGroups.Count -gt 0) { "Yellow" } else { "Green" })
if ($emptyGroups.Count -gt 0) {
    $emptyGroups | Select-Object GroupName, Source, Detail | Format-Table -AutoSize -Wrap | Out-String | Write-Host
    Write-Host "Empty groups are reported only - this script never deletes a group. Review each" -ForegroundColor Yellow
    Write-Host "before deciding whether to decommission it manually." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Full report: $reportFile"

Stop-Transcript | Out-Null
#endregion
