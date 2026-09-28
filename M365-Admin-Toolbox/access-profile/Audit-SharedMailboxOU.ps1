#Requires -Version 5.1
<#
.SYNOPSIS
    Audits every AD account already sitting in the Shared Mailbox OU and flags anything
    that Offboard-HybridUser.ps1 should have cleaned up but didn't (stragglers
    from before this automation existed, or partial/failed runs).

.DESCRIPTION
    THIS IS THE VENDOR-NEUTRAL VARIANT. Environment defaults are read from environment.psd1 beside this script - copy environment.example.psd1 and fill it in before first use. Every value there is a default; the equivalent parameter always wins.

    For every user object found in the OU, this script checks:
      - AD account still enabled (it shouldn't be - offboarded users are disabled)
      - Leftover local AD group memberships (anything besides the primary group)
      - Mailbox type in Exchange Online (should be Shared, not a regular user mailbox)
      - Entra ID AccountEnabled (should be $false)
      - Leftover Entra group memberships, using the same sync-aware logic as the
        offboarding script: synced groups are flagged as "should be removed in AD",
        cloud-only groups are flagged as "should be removed via Graph/Exchange Online"

    This is READ-ONLY by default - it only reports. Pass -Remediate to have it fix
    what it finds (reusing the same removal logic as the offboarding script), with
    -WhatIf support so you can preview remediation before it runs for real.

    Nothing here re-disables an already-disabled account correctly, converts a mailbox
    that was intentionally left as a regular mailbox, or second-guesses anyone who was
    deliberately re-added to a group after offboarding - it flags deviations from the
    expected "fully offboarded" state and lets you decide (or auto-fix, if you trust it).

.PARAMETER SharedMailboxOU
    Distinguished name of the OU to audit. Defaults to the configured shared mailbox OU.
    Pass this explicitly to audit a different OU.

.PARAMETER ReportPath
    Folder to write the CSV report and transcript log to. Defaults to a fixed, shared
    a Reports\SharedMailboxAudits subfolder inside this script's own package folder
    (resolved via $PSScriptRoot, so the package is portable) - not a relative ".\..." path, so reports
    always land in the same findable spot no matter what directory PowerShell happens to
    be in when you run this (e.g. C:\Windows\System32, which is where this ends up if
    launched from a shortcut/Run box without changing directory first).

.PARAMETER Remediate
    Fix what's found: disable AD accounts that are still enabled, remove leftover AD
    group memberships, convert mailboxes to shared, disable Entra sign-in, and remove
    leftover cloud group memberships. Supports -WhatIf.

.PARAMETER AutoInstallMissingModules
    If a required PSGallery module isn't installed, install it automatically instead
    of prompting. The ActiveDirectory module (RSAT) can never be auto-installed this way.

.PARAMETER WhatIf
    Preview remediation actions without making them. Has no effect on the audit/report
    portion, which never makes changes regardless.

.EXAMPLE
    .\Audit-SharedMailboxOU.ps1
    Report-only pass over your Shared Mailbox OU.

.EXAMPLE
    .\Audit-SharedMailboxOU.ps1 -Remediate -WhatIf
    Preview what remediation would do, without changing anything.

.EXAMPLE
    .\Audit-SharedMailboxOU.ps1 -Remediate
    Audit and fix everything it finds.

.NOTES
    Required modules  : ActiveDirectory, ExchangeOnlineManagement,
                         Microsoft.Graph.Users, Microsoft.Graph.Groups,
                         Microsoft.Graph.Identity.DirectoryManagement,
                         Microsoft.Graph.Identity.SignIns
    Required Graph scopes (delegated or app-only) :
                         User.ReadWrite.All, Group.ReadWrite.All,
                         GroupMember.ReadWrite.All, Directory.Read.All

    After -Remediate removes someone from a synced AD group, that removal won't be
    reflected in Entra until the next Entra Connect sync cycle runs. Re-running this
    script right after remediation may still show a since-removed synced group as
    flagged until sync catches up - that's expected, not a bug.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$SharedMailboxOU,

    [string]$ReportPath,

    [switch]$Remediate,

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
if (-not $ReportPath) { $ReportPath = Join-Path $Script:PackageRoot 'Reports\SharedMailboxAudits' }
# ---------------------------------------------------------------------------------------


#region 0. Configuration (the organization preset)

# --- environment configuration ---------------------------------------------
# Tenant specifics live in environment.psd1 beside this script rather than in
# the code. Every value is a default; the equivalent parameter still wins.
$Script:EnvConfig = @{}
$Script:EnvConfigPath = Join-Path $PSScriptRoot 'environment.psd1'
if (Test-Path -LiteralPath $Script:EnvConfigPath) {
    try {
        $Script:EnvConfig = Import-PowerShellDataFile -LiteralPath $Script:EnvConfigPath
    }
    catch {
        Write-Warning ("Could not read {0}: {1}" -f $Script:EnvConfigPath, $_.Exception.Message)
    }
}
else {
    Write-Warning ("No environment.psd1 found beside this script. Copy environment.example.psd1 and fill it in, or pass the values as parameters.")
}

function Get-EnvSetting {
    param([Parameter(Mandatory)][string]$Name, [string]$Default = '')
    if ($Script:EnvConfig.ContainsKey($Name) -and $Script:EnvConfig[$Name]) {
        return [string]$Script:EnvConfig[$Name]
    }
    return $Default
}
# ---------------------------------------------------------------------------

$Script:DefaultSharedMailboxOU = Get-EnvSetting -Name 'SharedMailboxOU'
#endregion

if (-not $SharedMailboxOU) { $SharedMailboxOU = $Script:DefaultSharedMailboxOU }

# Bump on any behaviour change; logged with each run so a saved report maps to a build.
$Script:ScriptVersion = "2026-08-06.1 (Exchange connection probe no longer throws NullReference on a fresh session)"

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[Object]

function Add-Result {
    param($User, $Category, $Action, $Status, $Detail = "")
    $results.Add([PSCustomObject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        User      = $User
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
$transcriptFile = Join-Path $ReportPath "AuditSharedMailboxOU_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $transcriptFile -Append | Out-Null

Write-Host "=== Auditing $SharedMailboxOU ===" -ForegroundColor Cyan
Write-Host "Reports will be saved to: $ReportPath" -ForegroundColor DarkCyan

#region 1. Load / verify modules
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

#region 2. Validate OU and enumerate users
if (-not (Get-ADOrganizationalUnit -Identity $SharedMailboxOU -ErrorAction SilentlyContinue)) {
    Stop-Transcript | Out-Null
    throw ("Could not find an OU with distinguished name '$SharedMailboxOU' in this domain. Double-check " +
           "it with: Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName")
}

$adUsers = Get-ADUser -SearchBase $SharedMailboxOU -Filter * -Properties Enabled, MemberOf, PrimaryGroupID, UserPrincipalName, mail
Write-Host "Found $($adUsers.Count) account(s) in the OU.`n"

if ($adUsers.Count -eq 0) {
    Write-Host "Nothing to audit - the OU is empty." -ForegroundColor Green
    Stop-Transcript | Out-Null
    return
}
#endregion

#region 3. Connect to Exchange Online and Graph once, up front
try {
    if (-not (Test-ExoConnected)) {
        Connect-ExchangeOnline -ShowBanner:$false
    }
}
catch {
    Write-Warning "Could not connect to Exchange Online: $($_.Exception.Message). Mailbox-type checks will be skipped."
}
try {
    if (-not (Get-MgContext)) {
        Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "GroupMember.ReadWrite.All", "Directory.Read.All" -NoWelcome
    }
}
catch {
    Write-Warning "Could not connect to Microsoft Graph: $($_.Exception.Message). Entra checks will be skipped."
}
#endregion

#region 4. Audit each user
foreach ($adUser in $adUsers) {
    $sam = $adUser.SamAccountName
    $upn = $adUser.UserPrincipalName
    $userFlagged = $false
    Write-Host "--- $sam ---" -ForegroundColor Cyan

    # 4a. AD account still enabled?
    if ($adUser.Enabled) {
        $userFlagged = $true
        Add-Result $sam "AD-Enabled" "Audit" "Flagged" "Account is still enabled in AD"
        if ($Remediate -and $PSCmdlet.ShouldProcess($sam, "Disable-ADAccount")) {
            try {
                Disable-ADAccount -Identity $adUser.DistinguishedName
                Add-Result $sam "AD-Enabled" "Remediate" "Fixed" "Disabled"
            }
            catch { Add-Result $sam "AD-Enabled" "Remediate" "Failed" $_.Exception.Message }
        }
    }
    else {
        Add-Result $sam "AD-Enabled" "Audit" "OK" "Account is disabled"
    }

    # 4b. Leftover local AD group memberships
    try {
        $adGroups = Get-ADPrincipalGroupMembership -Identity $adUser.DistinguishedName
    }
    catch {
        $adGroups = @()
        Add-Result $sam "AD-Groups" "Audit" "Failed" $_.Exception.Message
    }
    $primaryGroupSID = $adUser.SID.Value.Substring(0, $adUser.SID.Value.LastIndexOf('-')) + "-" + $adUser.PrimaryGroupID
    foreach ($grp in $adGroups) {
        if ($grp.SID.Value -eq $primaryGroupSID) { continue }
        $userFlagged = $true
        Add-Result $sam "AD-Group:$($grp.Name)" "Audit" "Flagged" "Still a member of AD group $($grp.Name)"
        if ($Remediate -and $PSCmdlet.ShouldProcess("$sam / $($grp.Name)", "Remove-ADGroupMember")) {
            try {
                Remove-ADGroupMember -Identity $grp.DistinguishedName -Members $adUser.DistinguishedName -Confirm:$false
                Add-Result $sam "AD-Group:$($grp.Name)" "Remediate" "Fixed" "Removed"
            }
            catch { Add-Result $sam "AD-Group:$($grp.Name)" "Remediate" "Failed" $_.Exception.Message }
        }
    }
    if (-not ($adGroups | Where-Object { $_.SID.Value -ne $primaryGroupSID })) {
        Add-Result $sam "AD-Groups" "Audit" "OK" "No leftover AD group memberships"
    }

    # 4c. Mailbox type
    try {
        $mbx = Get-Mailbox -Identity $upn -ErrorAction SilentlyContinue
        if (-not $mbx) {
            Add-Result $sam "Mailbox-Type" "Audit" "Info" "No mailbox found for this user"
        }
        elseif ($mbx.RecipientTypeDetails -ne 'SharedMailbox') {
            $userFlagged = $true
            Add-Result $sam "Mailbox-Type" "Audit" "Flagged" "Mailbox type is $($mbx.RecipientTypeDetails), not SharedMailbox"
            if ($Remediate -and $PSCmdlet.ShouldProcess($upn, "Set-Mailbox -Type Shared")) {
                try {
                    Set-Mailbox -Identity $upn -Type Shared
                    Add-Result $sam "Mailbox-Type" "Remediate" "Fixed" "Converted to shared"
                }
                catch { Add-Result $sam "Mailbox-Type" "Remediate" "Failed" $_.Exception.Message }
            }
        }
        else {
            Add-Result $sam "Mailbox-Type" "Audit" "OK" "Already a shared mailbox"
        }
    }
    catch {
        Add-Result $sam "Mailbox-Type" "Audit" "Failed" $_.Exception.Message
    }

    # 4d. Entra account state + cloud groups
    try {
        $mgUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property Id, UserPrincipalName, AccountEnabled -ErrorAction SilentlyContinue
        if (-not $mgUser) {
            Add-Result $sam "Entra-Lookup" "Audit" "Info" "Not found in Entra ID (not synced yet, or cloud-only account mismatch)"
        }
        else {
            if ($mgUser.AccountEnabled) {
                $userFlagged = $true
                Add-Result $sam "Entra-Enabled" "Audit" "Flagged" "Entra sign-in is not blocked (AccountEnabled = true)"
                if ($Remediate -and $PSCmdlet.ShouldProcess($upn, "Update-MgUser -AccountEnabled:`$false")) {
                    try {
                        Update-MgUser -UserId $mgUser.Id -AccountEnabled:$false
                        Revoke-MgUserSignInSession -UserId $mgUser.Id | Out-Null
                        Add-Result $sam "Entra-Enabled" "Remediate" "Fixed" "Disabled sign-in and revoked sessions"
                    }
                    catch { Add-Result $sam "Entra-Enabled" "Remediate" "Failed" $_.Exception.Message }
                }
            }
            else {
                Add-Result $sam "Entra-Enabled" "Audit" "OK" "Sign-in already blocked"
            }

            $memberOf = Get-MgUserMemberOf -UserId $mgUser.Id -All
            $cloudGroupCount = 0
            foreach ($m in $memberOf) {
                if ($m.AdditionalProperties['@odata.type'] -ne '#microsoft.graph.group') { continue }
                $cloudGroupCount++
                $groupId       = $m.Id
                $groupDetail   = Get-MgGroup -GroupId $groupId -Property Id, DisplayName, OnPremisesSyncEnabled, MailEnabled, GroupTypes
                $groupName     = $groupDetail.DisplayName
                $isSynced      = [bool]$groupDetail.OnPremisesSyncEnabled
                $isMailEnabled = [bool]$groupDetail.MailEnabled
                $isM365Group   = $groupDetail.GroupTypes -contains "Unified"
                $userFlagged = $true

                if ($isSynced) {
                    Add-Result $sam "Entra-Group:$groupName" "Audit" "Flagged" "Still in synced group $groupName - remove via AD, not here"
                    # Not remediated here even with -Remediate: removing a synced group's
                    # membership has to happen in AD, which this read-only-by-default audit
                    # script does handle above in 4b if the AD side still shows membership.
                    # If AD already shows it removed but Entra still shows it, that's a sync
                    # lag - re-run this audit after the next Entra Connect cycle.
                    continue
                }

                Add-Result $sam "Entra-Group:$groupName" "Audit" "Flagged" "Still in cloud group $groupName"
                if ($Remediate -and $PSCmdlet.ShouldProcess("$sam / $groupName", "Remove cloud group membership")) {
                    try {
                        if ($isMailEnabled -and -not $isM365Group) {
                            if (-not (Test-ExoConnected)) {
                                Connect-ExchangeOnline -ShowBanner:$false
                            }
                            Remove-DistributionGroupMember -Identity $groupName -Member $upn -Confirm:$false -BypassSecurityGroupManagerCheck
                        }
                        else {
                            Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $mgUser.Id
                        }
                        Add-Result $sam "Entra-Group:$groupName" "Remediate" "Fixed" "Removed"
                    }
                    catch { Add-Result $sam "Entra-Group:$groupName" "Remediate" "Failed" $_.Exception.Message }
                }
            }
            if ($cloudGroupCount -eq 0) {
                Add-Result $sam "Entra-Groups" "Audit" "OK" "No cloud group memberships"
            }
        }
    }
    catch {
        Add-Result $sam "Entra-Lookup" "Audit" "Failed" $_.Exception.Message
    }

    if (-not $userFlagged) {
        Write-Host "  Clean." -ForegroundColor Green
    }
    else {
        Write-Host "  Needs review - see report." -ForegroundColor Yellow
    }
}
#endregion

#region 5. Report
$reportFile = Join-Path $ReportPath "AuditSharedMailboxOU_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $reportFile -NoTypeInformation

$flaggedUsers = $results | Where-Object { $_.Status -eq 'Flagged' } | Select-Object -ExpandProperty User -Unique
Write-Host "`n=== Audit summary ===" -ForegroundColor Cyan
Write-Host "Accounts audited : $($adUsers.Count)"
Write-Host "Accounts flagged : $($flaggedUsers.Count)"
if ($flaggedUsers.Count -gt 0) {
    Write-Host "Flagged: $($flaggedUsers -join ', ')" -ForegroundColor Yellow
}
Write-Host "Full report: $reportFile"

Stop-Transcript | Out-Null
#endregion

