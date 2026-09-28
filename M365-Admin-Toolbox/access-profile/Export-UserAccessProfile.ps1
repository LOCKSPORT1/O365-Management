#Requires -Version 5.1
<#
.SYNOPSIS
    Exports a reference/template user's local AD group memberships, Entra ID group
    memberships, and assigned Entra ID licenses into a reusable JSON access profile.

.DESCRIPTION
    THIS IS THE VENDOR-NEUTRAL VARIANT. Environment defaults are read from environment.psd1 beside this script - copy environment.example.psd1 and fill it in before first use. Every value there is a default; the equivalent parameter always wins.

    Run this against a "template" user who already has the right access for a given
    role (e.g. a current Engineering team member) - not a random or leaving user. The
    output is a portable JSON file meant to be reviewed before it's ever applied to
    anyone with New-UserFromAccessProfile.ps1, since the group/license lists
    reflect exactly what the template user has at export time, including anything that
    might be a personal exception rather than a true role requirement.

    Captures:
      - The template user's own OU (parsed from their DistinguishedName) - used as the
        default OU for the new hire by New-UserFromAccessProfile.ps1, since a
        person cloned from this profile normally belongs in the same OU as the template.
      - Local AD security/distribution groups (excluding the user's primary group,
        same as the offboarding script - primary group membership isn't meaningful
        to copy to a new user).
      - Entra ID group memberships, tagged synced / cloud-only / dynamic so
        New-UserFromAccessProfile.ps1 knows how to handle each one later:
          - Synced groups: added on the AD side only when applied - Entra reflects
            them automatically after the next sync, same group list as above.
          - Cloud-only groups: added directly via Microsoft Graph when applied.
          - Dynamic groups: can't be manually added to anyone. Recorded for visibility
            only - the new user will join automatically if they happen to match the
            group's own rule (e.g. an "All Users" style group), not because this
            profile added them.
      - Assigned Entra ID license SKUs (SkuId + human-readable SkuPartNumber).
      - The template user's Entra ID UsageLocation (e.g. "US") - Microsoft Graph won't
        assign a license to a user until their usage location is set, so this is captured
        for New-UserFromAccessProfile.ps1 to apply automatically.

    This script only reads data - it never modifies the template user in any way.

.PARAMETER SamAccountName
    On-prem AD SamAccountName of the reference/template user to export access from.

.PARAMETER ProfileName
    Name for the saved profile; becomes <ProfileName>.json in the AccessProfiles folder.

    If omitted, defaults to the template user's AD **Department** - a profile is a role
    template, so "Engineering.json" stays reusable where "jdoe.json" is opaque later and
    carries an employee name around. Falls back to the SamAccountName only when the
    account has no Department set.

    When run interactively without -ProfileName you get a confirmation prompt pre-filled
    with that suggestion, so you can narrow it (e.g. "Engineering-Drafter") when one
    department needs several templates. Supplying -ProfileName skips the prompt entirely,
    so scheduled and scripted runs never hang.

    The name is sanitized for the filesystem - illegal characters dropped, whitespace
    collapsed to dashes ("Project Management" becomes "Project-Management"). Overwriting
    an existing profile asks first and shows what's being replaced.

.PARAMETER ProfilePath
    Folder to write the JSON profile into. Defaults to a fixed, shared location:
    an AccessProfiles subfolder inside this script's own package folder (resolved via
    $PSScriptRoot, so the package is portable) - not a relative ".\..." path, so profiles always land
    in the same findable spot no matter what directory PowerShell happens to be in when
    you run this (e.g. C:\Windows\System32, which is where this ends up if launched from
    a shortcut/Run box without changing directory first).

.PARAMETER AutoInstallMissingModules
    If a required PSGallery module (Microsoft.Graph.*) isn't installed, install it
    automatically for the current user instead of prompting. The ActiveDirectory module
    (RSAT) can never be auto-installed this way - see .NOTES.

.EXAMPLE
    .\Export-UserAccessProfile.ps1 -SamAccountName jdoe -ProfileName "Engineering-NewHire"

.EXAMPLE
    .\Export-UserAccessProfile.ps1 -SamAccountName jdoe
    (Profile file named jdoe.json, since -ProfileName was omitted.)

.NOTES
    Required modules : ActiveDirectory, Microsoft.Graph.Users, Microsoft.Graph.Groups,
                        Microsoft.Graph.Identity.DirectoryManagement
    Required Graph scopes (delegated or app-only) : User.Read.All, Group.Read.All,
                        Directory.Read.All

    Run this from an admin workstation with the ActiveDirectory RSAT module installed,
    or from a domain controller. The Graph connection happens over the internet
    regardless of where the script runs.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [string]$SamAccountName,

    [string]$ProfileName,

    [string]$ProfilePath,

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
if (-not $ProfilePath) { $ProfilePath = Join-Path $Script:PackageRoot 'AccessProfiles' }
# ---------------------------------------------------------------------------------------


$ErrorActionPreference = 'Stop'

# Ensures a required module is available, importing it if present, offering to install it
# if it's missing and comes from PSGallery, or explaining how to get it if it doesn't
# (currently only ActiveDirectory/RSAT, which is a Windows feature, not a gallery module).
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

if (-not (Test-Path $ProfilePath)) {
    New-Item -Path $ProfilePath -ItemType Directory -Force | Out-Null
}

Write-Host "=== Exporting access profile from $SamAccountName ===" -ForegroundColor Cyan
Write-Host "Profile will be saved to: $ProfilePath" -ForegroundColor DarkCyan

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

#region 2. Look up AD user and local AD groups
try {
    $adUser = Get-ADUser -Identity $SamAccountName -Properties MemberOf, PrimaryGroupID, UserPrincipalName, Department, Title
}
catch {
    throw "Could not find AD user '$SamAccountName': $_"
}
$upn = $adUser.UserPrincipalName

#region 2a. Decide the profile name
# A profile is a ROLE TEMPLATE, not a person record - "Engineering.json" stays meaningful
# and reusable, where "jdoe.json" is opaque six months later and drags an employee name
# into a file that gets copied around. So default the name to the template user's AD
# Department, and only fall back to the SamAccountName when Department is empty.
#
# -ProfileName always wins if supplied, so unattended/scripted runs never prompt.
$Script:ProfileNameSource = 'explicit -ProfileName'
if (-not $ProfileName) {
    if ($adUser.Department) {
        $ProfileName = $adUser.Department
        $Script:ProfileNameSource = "AD Department of $SamAccountName"
    }
    else {
        $ProfileName = $SamAccountName
        $Script:ProfileNameSource = "SamAccountName ($SamAccountName has no Department set in AD)"
    }

    # Interactive confirmation, pre-filled with the suggestion. Skipped when there's no
    # console to prompt on (scheduled task, remoting, CI) so automation can't hang.
    $canPrompt = $Host.UI.RawUI -and -not [Console]::IsInputRedirected
    if ($canPrompt) {
        Write-Host ""
        Write-Host "Profile name" -ForegroundColor Cyan
        Write-Host "  Suggested : $ProfileName   (from $Script:ProfileNameSource)"
        if ($adUser.Title) { Write-Host "  Job title : $($adUser.Title)   - append it for a narrower template, e.g. '$ProfileName-$($adUser.Title)'" }
        Write-Host "  One department can hold several role templates; name it for the ROLE a new"
        Write-Host "  hire is being cloned into, not for the person you copied from."
        Write-Host ""
        $answer = Read-Host "  Profile name [$ProfileName]"
        if ($answer) {
            $ProfileName = $answer
            $Script:ProfileNameSource = 'entered at prompt'
        }
    }
}

# Filenames: strip anything illegal, collapse whitespace to single dashes. Done after the
# prompt so a typed name gets sanitized too ("Project Management" -> "Project-Management").
$rawProfileName = $ProfileName
$invalid = [IO.Path]::GetInvalidFileNameChars() -join ''
$ProfileName = ($ProfileName -replace "[$([regex]::Escape($invalid))]", '') -replace '\s+', '-'
$ProfileName = $ProfileName.Trim('-', '.', ' ')
if (-not $ProfileName) { throw "Profile name '$rawProfileName' is empty once invalid filename characters are removed. Pass a usable -ProfileName." }
if ($ProfileName -ne $rawProfileName) {
    Write-Host "  Profile name sanitized for the filesystem: '$rawProfileName' -> '$ProfileName'" -ForegroundColor DarkYellow
}
Write-Host "Profile name: $ProfileName  (source: $Script:ProfileNameSource)" -ForegroundColor DarkCyan
#endregion
# The template user's own OU - a new hire cloned from this profile normally belongs in
# the same OU as the template user, so this is captured for New-UserFromAccessProfile-
# the organization.ps1 to use as its default -TargetOU (it can still be overridden per-run).
$sourceUserOU = $adUser.DistinguishedName -replace '^CN=[^,]+,', ''
Write-Host "Found AD user: $($adUser.DistinguishedName)"
Write-Host "UPN: $upn"
Write-Host "OU: $sourceUserOU"

# Primary group (usually "Domain Users") isn't meaningful to copy - every new user gets
# their own primary group assignment automatically. Build its SID the same way the
# offboarding script does, so it can be excluded here too.
$primaryGroupSID = $adUser.SID.Value.Substring(0, $adUser.SID.Value.LastIndexOf('-')) + "-" + $adUser.PrimaryGroupID

$adGroups = @(
    Get-ADPrincipalGroupMembership -Identity $adUser.DistinguishedName |
        Where-Object { $_.SID.Value -ne $primaryGroupSID } |
        ForEach-Object {
            [PSCustomObject]@{
                Name              = $_.Name
                DistinguishedName = $_.DistinguishedName
            }
        }
)
Write-Host "Local AD groups found: $($adGroups.Count)"
#endregion

#region 3. Connect to Graph and look up Entra user
if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All", "Directory.Read.All" -NoWelcome
}

$mgUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property Id, UserPrincipalName, UsageLocation
if (-not $mgUser) {
    throw "Could not find '$upn' in Entra ID - hybrid sync may not have completed yet, or this account is AD-only."
}
if (-not $mgUser.UsageLocation) {
    Write-Warning "Template user has no UsageLocation set in Entra - license assignment requires one. New-UserFromAccessProfile.ps1 will fall back to its own default if this profile doesn't have one."
}
#endregion

#region 4. Entra group memberships, tagged by type
$memberOf = Get-MgUserMemberOf -UserId $mgUser.Id -All
$entraGroups = @(
    foreach ($m in $memberOf) {
        # memberOf can include directory roles too - only act on actual groups
        if ($m.AdditionalProperties['@odata.type'] -ne '#microsoft.graph.group') { continue }

        $groupDetail = Get-MgGroup -GroupId $m.Id -Property Id, DisplayName, OnPremisesSyncEnabled, MailEnabled, GroupTypes
        [PSCustomObject]@{
            GroupId       = $groupDetail.Id
            GroupName     = $groupDetail.DisplayName
            IsSynced      = [bool]$groupDetail.OnPremisesSyncEnabled
            IsDynamic     = $groupDetail.GroupTypes -contains "DynamicMembership"
            IsMailEnabled = [bool]$groupDetail.MailEnabled
            IsM365Group   = $groupDetail.GroupTypes -contains "Unified"
        }
    }
)
$dynamicCount = @($entraGroups | Where-Object IsDynamic).Count
Write-Host "Entra ID groups found: $($entraGroups.Count) ($dynamicCount dynamic - won't be added directly when applied)"
#endregion

#region 5. Assigned Entra ID licenses
$licenseDetails = Get-MgUserLicenseDetail -UserId $mgUser.Id
$licenses = @(
    foreach ($lic in $licenseDetails) {
        [PSCustomObject]@{
            SkuId         = $lic.SkuId
            SkuPartNumber = $lic.SkuPartNumber
        }
    }
)
Write-Host "Licenses found: $($licenses.Count)"
#endregion

#region 6. Build and write the profile
$profile = [PSCustomObject]@{
    ProfileName   = $ProfileName
    SourceUser    = $upn
    SourceDept    = $adUser.Department
    SourceTitle   = $adUser.Title
    SourceUserOU  = $sourceUserOU
    UsageLocation = $mgUser.UsageLocation
    ExportedDate  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    ADGroups      = $adGroups
    EntraGroups   = $entraGroups
    Licenses      = $licenses
}

$outFile = Join-Path $ProfilePath "$ProfileName.json"

# Department-based names collide on purpose (that's what makes them reusable), so never
# overwrite silently - an existing template may be the one everyone provisions from.
if (Test-Path $outFile) {
    $existing = $null
    try { $existing = Get-Content $outFile -Raw | ConvertFrom-Json } catch { }
    Write-Host ""
    Write-Warning "A profile named '$ProfileName' already exists:"
    Write-Host "    $outFile"
    if ($existing) {
        Write-Host "    exported $($existing.ExportedDate) from $($existing.SourceUser)"
        Write-Host "    $(@($existing.ADGroups).Count) AD groups, $(@($existing.EntraGroups).Count) Entra groups, $(@($existing.Licenses).Count) licenses"
    }
    Write-Host "    replacing it with: $upn ($($adGroups.Count) AD, $($entraGroups.Count) Entra, $($licenses.Count) licenses)"
    Write-Host ""
    if (-not $PSCmdlet.ShouldProcess($outFile, "Overwrite existing access profile '$ProfileName'")) {
        Write-Host "Not overwritten. Re-run with a different -ProfileName to keep both." -ForegroundColor Yellow
        return
    }
}

$profile | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding UTF8

Write-Host "`n=== Profile written: $outFile ===" -ForegroundColor Green
Write-Host "AD groups: $($adGroups.Count)  |  Entra groups: $($entraGroups.Count) ($dynamicCount dynamic)  |  Licenses: $($licenses.Count)"
Write-Host "Review this file before using it with New-UserFromAccessProfile.ps1 - it's a plain-text copy of exactly what $upn had at export time." -ForegroundColor Yellow
#endregion

