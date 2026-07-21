#Requires -Version 5.1
<#
.SYNOPSIS
    Exports a reference/template user's local AD group memberships, Entra ID group
    memberships, and assigned Entra ID licenses into a reusable JSON access profile.

.DESCRIPTION
    This is a PORTABLE, VENDOR-NEUTRAL template: there's nothing environment-specific to
    configure in this script - it just reads whatever user you point it at. A your tenant
    tenant copy of this script lives in the your tenant toolkit's own access-profile\
    folder - the two are functionally identical, this one just doesn't assume any
    particular company's tenant in its comments.

    Run this against a "template" user who already has the right access for a given
    role (e.g. a current Engineering team member) - not a random or leaving user. The
    output is a portable JSON file meant to be reviewed before it's ever applied to
    anyone with New-UserFromAccessProfile.ps1, since the group/license lists reflect
    exactly what the template user has at export time, including anything that might be
    a personal exception rather than a true role requirement.

    Captures:
      - The template user's own OU (parsed from their DistinguishedName) - used as the
        default OU for the new hire by New-UserFromAccessProfile.ps1, since a person
        cloned from this profile normally belongs in the same OU as the template.
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
    Friendly name for this profile (e.g. "Engineering-NewHire"). Used to name the output
    JSON file and stored inside it. Defaults to the SamAccountName if omitted.

.PARAMETER ProfilePath
    Folder to write the JSON profile into. Defaults to .\AccessProfiles.

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

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SamAccountName,

    [string]$ProfileName,

    [string]$ProfilePath = ".\AccessProfiles",

    [switch]$AutoInstallMissingModules
)

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

if (-not $ProfileName) { $ProfileName = $SamAccountName }
if (-not (Test-Path $ProfilePath)) {
    New-Item -Path $ProfilePath -ItemType Directory -Force | Out-Null
}

Write-Host "=== Exporting access profile from $SamAccountName ===" -ForegroundColor Cyan

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
    $adUser = Get-ADUser -Identity $SamAccountName -Properties MemberOf, PrimaryGroupID, UserPrincipalName
}
catch {
    throw "Could not find AD user '$SamAccountName': $_"
}
$upn = $adUser.UserPrincipalName
# The template user's own OU - a new hire cloned from this profile normally belongs in
# the same OU as the template user, so this is captured for New-UserFromAccessProfile.ps1
# to use as its default -TargetOU (it can still be overridden per-run).
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
    SourceUserOU  = $sourceUserOU
    UsageLocation = $mgUser.UsageLocation
    ExportedDate  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    ADGroups      = $adGroups
    EntraGroups   = $entraGroups
    Licenses      = $licenses
}

$outFile = Join-Path $ProfilePath "$ProfileName.json"
$profile | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding UTF8

Write-Host "`n=== Profile written: $outFile ===" -ForegroundColor Green
Write-Host "AD groups: $($adGroups.Count)  |  Entra groups: $($entraGroups.Count) ($dynamicCount dynamic)  |  Licenses: $($licenses.Count)"
Write-Host "Review this file before using it with New-UserFromAccessProfile.ps1 - it's a plain-text copy of exactly what $upn had at export time." -ForegroundColor Yellow
#endregion
