#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a new on-prem AD user and provisions them with the same local AD groups,
    Entra ID groups, and Entra ID licenses captured in a JSON access profile produced by
    Export-UserAccessProfile.ps1.

.DESCRIPTION
    This is a PORTABLE, VENDOR-NEUTRAL template: nothing about a specific OU path, domain
    name, or tenant is hard-coded. -TargetOU, the new user's UPN domain, and
    -UsageLocation normally come from the access profile itself (the template user's own
    OU, email domain, and usage location, captured by Export-UserAccessProfile.ps1) - you
    don't need to set any of these for a typical run. Section "0. Configuration" below
    only holds last-resort fallbacks, used if you explicitly pass a param and the profile
    happens to be missing that data (e.g. an older profile). See ".NOTES > Finding your
    environment-specific values" if you do need to set the fallbacks. A tenant-preset
    copy of this script, with its Section 0 fallbacks preset to your tenant's real values,
    lives in the your tenant toolkit's own access-profile\ folder.

    Pipeline:
      1. If -SamAccountName wasn't given, generate one from -GivenName/-Surname as
         first-initial + surname (John Smith -> JSmith), appending an incrementing number
         on collision (JSmith2, JSmith3, ...).
      2. Load the JSON access profile from -ProfilePath (see Export-UserAccessProfile.ps1
         to create one from a template user). Resolve -TargetOU and the UPN domain:
         explicit param > the profile's own values > section 0 fallback.
      3. Create the new on-prem AD user (New-ADUser) in the resolved OU, enabled, with a
         temporary password the user must change at first logon.
      4. Add the new user to every local AD group listed in the profile.
      5. Optionally trigger an Entra Connect delta sync and wait for it, so the new
         account and its AD group memberships propagate to Entra before cloud steps run.
      6. Connect to Microsoft Graph and look up the new user's Entra ID object. Set their
         UsageLocation (required before Graph will allow any license assignment). For
         each Entra group in the profile:
           - Synced group  -> already handled by the matching AD group in step 4; no
             direct action, it'll show up in Entra after sync.
           - Dynamic membership group -> skipped; can't be manually added to anyone. The
             new user only joins automatically if they happen to match the group's own
             rule (e.g. an "All Users" style group) - not because of this script.
           - Cloud-only group -> add directly via Microsoft Graph.
      7. Assign every license SKU listed in the profile (one Set-MgUserLicense call per
         SKU, so a single SKU running out of seats doesn't block the others).
      8. Emit a per-user CSV report of every action taken and its outcome.

    -CLOUDONLY MODE: if a previous run created the AD account but failed on the cloud
    side before Entra Connect had synced the new account (a common timing issue - see
    -EntraConnectServer below), re-running this script normally throws "AD user already
    exists" at step 3's pre-condition check. Pass -CloudOnly -SamAccountName <name> to
    skip steps 1, 3, and 4 entirely (no name generation, no New-ADUser, no AD group
    provisioning - all logged as "Skipped") and go straight to step 5 onward against the
    existing AD account: UPN is read directly off that account instead of constructed,
    -GivenName/-Surname become optional (unused in this mode), and steps 5-8 (sync wait,
    UsageLocation, cloud groups, licenses, report) run exactly as normal.

    SECURITY NOTE ON THE TEMPORARY PASSWORD: unlike the other scripts in this set, this
    one deliberately does NOT call Start-Transcript. If a password is auto-generated (see
    -InitialPassword below), it is shown once in the console and is never written to any
    log or report file by this script - only you see it, and only once. Copy it
    immediately to whatever secure channel you use to hand credentials to a new hire.

.PARAMETER ProfilePath
    Path to the JSON access profile file (from Export-UserAccessProfile.ps1),
    e.g. .\AccessProfiles\Engineering-NewHire.json.

.PARAMETER SamAccountName
    Logon name for the new user being created. Optional - if omitted, it's generated from
    -GivenName/-Surname as first-initial + surname (John Smith -> JSmith). If that name is
    already taken in AD, an incrementing number is appended (JSmith2, JSmith3, ...) until
    an unused name is found. Pass this explicitly to override the generated name.

.PARAMETER CloudOnly
    Skip AD account creation and AD group provisioning entirely, and instead finish cloud
    provisioning (Entra sync wait, UsageLocation, cloud groups, licenses) for an AD account
    that already exists - use this to resume after a run where the AD side succeeded but
    the cloud side failed because the account hadn't synced to Entra yet. Requires
    -SamAccountName (there's no name to generate/target otherwise); -GivenName/-Surname
    are not needed in this mode. The UPN is read directly from the existing AD account
    instead of being constructed from -TargetOU/profile/section-0 defaults.

.PARAMETER GivenName
    New user's first name. Not required when -CloudOnly is specified.

.PARAMETER Surname
    New user's last name. Not required when -CloudOnly is specified.

.PARAMETER UserPrincipalName
    New user's UPN. If omitted, defaults to "<SamAccountName>@<domain>" using the same
    email domain as the profile's template user (SourceUser); falls back to the section
    "0. Configuration" suffix only if the profile doesn't have that.

.PARAMETER EmailAddress
    New user's email address. Defaults to the same value as -UserPrincipalName if omitted.

.PARAMETER TargetOU
    Distinguished name of the OU to create the new AD user in. If omitted, defaults to
    the profile's SourceUserOU (the template user's own OU) - a new hire cloned from a
    profile normally belongs in the same OU as the template. Falls back to the section
    "0. Configuration" placeholder only if the profile doesn't have that value.

.PARAMETER UsageLocation
    Two-letter country code (e.g. "US") required by Microsoft Graph before it will assign
    any license to a user. If omitted, defaults to the profile's UsageLocation (the
    template user's own); falls back to the section "0. Configuration" placeholder only
    if the profile doesn't have that value.

.PARAMETER Department
    Optional AD "Department" attribute to set on the new user.

.PARAMETER Title
    Optional AD "Title" attribute to set on the new user.

.PARAMETER InitialPassword
    Temporary password for the new account, as a SecureString. If omitted, a random
    16-character complex password is generated and shown once in the console (see the
    SECURITY NOTE above) - the account is created with -ChangePasswordAtLogon, so this
    is only ever meant to be used once.

.PARAMETER EntraConnectServer
    Hostname of the Entra Connect / AD Connect server, used to remotely trigger
    Start-ADSyncSyncCycle over PowerShell remoting. Omit if you trigger sync another way.
    See .NOTES for how to find this.

.PARAMETER SkipEntraSyncWait
    Skip triggering/waiting on an Entra Connect delta sync before the cloud steps run.
    Only use this if you already know a sync has run very recently, otherwise the new
    user may not exist in Entra yet when step 5 looks for them.

.PARAMETER SyncWaitTimeoutSeconds
    Max seconds to wait for the triggered sync to finish. Defaults to 300 (5 minutes).

.PARAMETER ReportPath
    Folder to write the per-run CSV report to. Defaults to .\ProvisioningReports.

.PARAMETER AutoInstallMissingModules
    If a required PSGallery module isn't installed, install it automatically for the
    current user instead of prompting. The ActiveDirectory module (RSAT) can never be
    auto-installed this way - see .NOTES.

.PARAMETER WhatIf
    Standard ShouldProcess support - preview every change without making it. Note the
    account-existence and OU checks still run for real, since they're read-only.

.EXAMPLE
    .\New-UserFromAccessProfile.ps1 -ProfilePath .\AccessProfiles\Engineering-NewHire.json -GivenName John -Surname Smith -TargetOU "OU=Users,DC=contoso,DC=com" -UserPrincipalName jsmith@contoso.com -EntraConnectServer AADC01
    (No -SamAccountName given - generates "JSmith", or "JSmith2" etc. if that's taken.)

.EXAMPLE
    .\New-UserFromAccessProfile.ps1 -ProfilePath .\AccessProfiles\Engineering-NewHire.json -SamAccountName jdoe2 -GivenName Jane -Surname Doe -WhatIf
    (Explicit -SamAccountName overrides the generated name; uses whatever defaults are set in section "0. Configuration" below.)

.EXAMPLE
    .\New-UserFromAccessProfile.ps1 -ProfilePath .\AccessProfiles\Engineering-NewHire.json -SamAccountName CLister -CloudOnly
    (AD account "CLister" already exists from a prior run - skips AD creation/groups and
    finishes cloud provisioning: sync wait, UsageLocation, cloud groups, licenses.)

.NOTES
    Required modules  : ActiveDirectory, Microsoft.Graph.Users, Microsoft.Graph.Groups,
                         Microsoft.Graph.Identity.DirectoryManagement,
                         Microsoft.Graph.Users.Actions
    Required Graph scopes (delegated or app-only) :
                         User.ReadWrite.All, Group.ReadWrite.All,
                         GroupMember.ReadWrite.All, Directory.Read.All

    This script does not create a mailbox directly. If any assigned license SKU includes
    Exchange Online, Exchange auto-provisions the mailbox once the license takes effect
    and the next directory sync/license processing cycle completes - typically within a
    few minutes, sometimes longer. No separate mailbox-creation step is needed here.

    FINDING YOUR ENVIRONMENT-SPECIFIC VALUES
    -----------------------------------------
    TargetOU (the distinguished name of your new-hire / standard users OU):
      - GUI: open Active Directory Users and Computers (dsa.msc) -> View menu -> check
        "Advanced Features" -> right-click the target OU -> Properties -> Attribute
        Editor tab -> find "distinguishedName" -> copy its value.
      - PowerShell (run on a machine with the ActiveDirectory module):
            Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName

    UPN suffix (the part after @ in your users' sign-in names):
      - Check an existing user: Get-ADUser -Identity someuser -Properties UserPrincipalName
      - Or in Entra: whatever domain is verified/primary on your tenant.

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
    [string]$ProfilePath,

    [string]$SamAccountName,

    [switch]$CloudOnly,

    [string]$GivenName,

    [string]$Surname,

    [string]$UserPrincipalName,

    [string]$EmailAddress,

    [string]$TargetOU,

    [string]$UsageLocation,

    [string]$Department,

    [string]$Title,

    [System.Security.SecureString]$InitialPassword,

    [string]$EntraConnectServer,

    [switch]$SkipEntraSyncWait,

    [int]$SyncWaitTimeoutSeconds = 300,

    [string]$ReportPath = ".\ProvisioningReports",

    [switch]$AutoInstallMissingModules
)

#region 0. Configuration
# ---------------------------------------------------------------------------------------
# These are LAST-RESORT fallbacks only. -TargetOU, the UPN domain, and -UsageLocation
# normally come from the access profile itself (the template user's own OU, email domain,
# and usage location - see section 1b below), so most runs won't need any of these set.
# They only kick in if you pass a param explicitly AND the profile is missing that data
# (e.g. an older profile exported before this script tracked it), or as a last fallback if
# neither is available.
#
# See .NOTES above ("Finding your environment-specific values") for how to look these up
# if you do need to set them.
# ---------------------------------------------------------------------------------------
$Script:DefaultNewUserOU     = "OU=CHANGE-ME,DC=CHANGE-ME,DC=CHANGE-ME"
$Script:DefaultUpnSuffix     = "CHANGE-ME.com"
$Script:DefaultUsageLocation = "CHANGE-ME"
#endregion

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

# Generates a random complex password (upper + lower + digit + special, guaranteed one of
# each) when -InitialPassword isn't supplied. Not persisted anywhere by this script.
function New-RandomPassword {
    param([int]$Length = 16)
    $upper   = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = [char[]]'abcdefghijkmnpqrstuvwxyz'
    $digits  = [char[]]'23456789'
    $special = [char[]]'!@#$%^&*-_=+'
    $all     = $upper + $lower + $digits + $special

    $passwordChars = [System.Collections.Generic.List[char]]::new()
    $passwordChars.Add(($upper   | Get-Random))
    $passwordChars.Add(($lower   | Get-Random))
    $passwordChars.Add(($digits  | Get-Random))
    $passwordChars.Add(($special | Get-Random))
    for ($i = $passwordChars.Count; $i -lt $Length; $i++) {
        $passwordChars.Add(($all | Get-Random))
    }
    -join ($passwordChars | Sort-Object { Get-Random })
}

# Derives a SamAccountName from first-initial + surname (John Smith -> JSmith) when
# -SamAccountName isn't supplied. Checks AD for a collision and appends an incrementing
# number (JSmith2, JSmith3, ...) until it finds one that's free, respecting the 20-char
# SamAccountName limit.
function New-UniqueSamAccountName {
    param(
        [Parameter(Mandatory)] [string]$GivenName,
        [Parameter(Mandatory)] [string]$Surname
    )
    $baseName = ("{0}{1}" -f $GivenName.Substring(0, 1), $Surname) -replace '[^a-zA-Z0-9]', ''
    if ($baseName.Length -gt 20) { $baseName = $baseName.Substring(0, 20) }

    $candidate = $baseName
    $suffix = 1
    while (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction SilentlyContinue) {
        $suffix++
        $suffixText  = "$suffix"
        $trimLength  = [Math]::Max(1, 20 - $suffixText.Length)
        $candidate   = $baseName.Substring(0, [Math]::Min($baseName.Length, $trimLength)) + $suffixText
    }
    return $candidate
}

Write-Host "=== Provisioning new user from profile: $ProfilePath ===" -ForegroundColor Cyan

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

#region 1a. Determine SamAccountName and validate name inputs
$existingAdUser = $null
if ($CloudOnly) {
    if (-not $SamAccountName) {
        throw "-SamAccountName is required when -CloudOnly is specified - there's no existing account to target otherwise."
    }
    $existingAdUser = Get-ADUser -Identity $SamAccountName -Properties UserPrincipalName, DistinguishedName -ErrorAction SilentlyContinue
    if (-not $existingAdUser) {
        throw "-CloudOnly was specified but AD user '$SamAccountName' was not found. Double-check the SamAccountName, or omit -CloudOnly to create a new account."
    }
}
else {
    if (-not $GivenName -or -not $Surname) {
        throw "-GivenName and -Surname are required unless -CloudOnly is specified."
    }
    if (-not $SamAccountName) {
        $SamAccountName = New-UniqueSamAccountName -GivenName $GivenName -Surname $Surname
        Write-Host "No -SamAccountName given - generated '$SamAccountName' from $GivenName $Surname (first initial + surname, incrementing on collision)."
    }
}
Write-Host ("=== Provisioning $SamAccountName" + $(if ($CloudOnly) { " (cloud-only - existing AD account)" }) + " ===") -ForegroundColor Cyan
#endregion

#region 1b. Load the access profile
if (-not (Test-Path $ProfilePath)) {
    throw "Access profile not found: $ProfilePath"
}
try {
    $profileData = Get-Content -Path $ProfilePath -Raw | ConvertFrom-Json
}
catch {
    throw "Could not parse '$ProfilePath' as JSON: $($_.Exception.Message)"
}
$adGroupsFromProfile    = @($profileData.ADGroups)
$entraGroupsFromProfile = @($profileData.EntraGroups)
$licensesFromProfile    = @($profileData.Licenses)
Write-Host "Profile '$($profileData.ProfileName)' loaded (source: $($profileData.SourceUser), exported $($profileData.ExportedDate))"
Write-Host "  AD groups: $($adGroupsFromProfile.Count)  |  Entra groups: $($entraGroupsFromProfile.Count)  |  Licenses: $($licensesFromProfile.Count)"

if ($CloudOnly) {
    # Account already exists - TargetOU is irrelevant (no New-ADUser call), and the real
    # UPN already living on the AD object is authoritative, not something to construct.
    if (-not $UserPrincipalName) {
        $UserPrincipalName = $existingAdUser.UserPrincipalName
        Write-Host "Using existing AD account's UPN: $UserPrincipalName"
    }
}
else {
    # Resolve -TargetOU: explicit param wins, then the profile's own SourceUserOU (the
    # template user's OU - a new hire cloned from this profile normally belongs there too),
    # then the section 0 fallback as a last resort.
    if (-not $TargetOU) {
        if ($profileData.SourceUserOU) {
            $TargetOU = $profileData.SourceUserOU
            Write-Host "Using -TargetOU from profile (template user's own OU): $TargetOU"
        }
        else {
            $TargetOU = $Script:DefaultNewUserOU
            Write-Host "Profile has no SourceUserOU (older profile?) - falling back to the section 0 default."
        }
    }

    # Resolve the UPN domain the same way: explicit -UserPrincipalName wins, then the domain
    # portion of the profile's SourceUser UPN, then the section 0 fallback suffix.
    if (-not $UserPrincipalName) {
        if ($profileData.SourceUser -and $profileData.SourceUser -match '@') {
            $upnSuffix = $profileData.SourceUser.Split('@')[1]
            $UserPrincipalName = "$SamAccountName@$upnSuffix"
            Write-Host "Using UPN domain from profile (template user's own domain): @$upnSuffix"
        }
        else {
            $UserPrincipalName = "$SamAccountName@$Script:DefaultUpnSuffix"
        }
    }
}
if (-not $EmailAddress) { $EmailAddress = $UserPrincipalName }

# Resolve -UsageLocation the same way: explicit param wins, then the profile's own
# UsageLocation (the template user's own), then the section 0 fallback. Microsoft Graph
# refuses to assign a license to a user with no usage location set, so this matters
# whenever the profile includes any licenses.
if (-not $UsageLocation) {
    if ($profileData.UsageLocation) {
        $UsageLocation = $profileData.UsageLocation
        Write-Host "Using -UsageLocation from profile (template user's own usage location): $UsageLocation"
    }
    else {
        $UsageLocation = $Script:DefaultUsageLocation
        Write-Host "Profile has no UsageLocation (older profile, or template user had none set) - falling back to the section 0 default."
    }
}
#endregion

#region 2. Validate configuration and pre-conditions
$passwordWasGenerated = $false
if ($CloudOnly) {
    # Existence already confirmed in region 1a ($existingAdUser) - nothing further to
    # validate here; TargetOU/password/name fields aren't used in this mode.
}
else {
    if (-not $TargetOU -or $TargetOU -like "*CHANGE-ME*") {
        throw ("-TargetOU could not be resolved from a param, the profile, or the section 0 " +
               "default (still a placeholder). Pass -TargetOU 'OU=...,DC=...,DC=...', use a " +
               "profile that has SourceUserOU set, or edit `$Script:DefaultNewUserOU in this script.")
    }
    if ($UserPrincipalName -like "*CHANGE-ME*") {
        throw ("-UserPrincipalName could not be resolved from a param, the profile, or the " +
               "section 0 default (still a placeholder). Pass -UserPrincipalName explicitly, " +
               "use a profile whose SourceUser has a real UPN, or edit " +
               "`$Script:DefaultUpnSuffix in this script.")
    }
    if (-not (Get-ADOrganizationalUnit -Identity $TargetOU -ErrorAction SilentlyContinue)) {
        throw ("Could not find an OU with distinguished name '$TargetOU' in this domain. Double-check " +
               "it with: Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName")
    }
    if (Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -ErrorAction SilentlyContinue) {
        throw ("AD user '$SamAccountName' already exists. This script is for creating new users only. " +
               "If the AD account is already there and you just need to finish cloud provisioning " +
               "(groups/license/usage location), re-run with -CloudOnly instead.")
    }
}
#endregion

#region 3. Create the new AD user
if (-not $CloudOnly) {
    if (-not $InitialPassword) {
        $plainPassword   = New-RandomPassword
        $InitialPassword = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
        $passwordWasGenerated = $true
    }
}

$newAdUser = $null
if ($CloudOnly) {
    $newAdUser = $existingAdUser
    Add-Result "AD" $SamAccountName "New-ADUser" "Skipped" "CloudOnly specified - using existing account, DN: $($existingAdUser.DistinguishedName)"
}
else {
    $displayName = "$GivenName $Surname"
    $newUserParams = @{
        Name                  = $displayName
        GivenName             = $GivenName
        Surname               = $Surname
        SamAccountName        = $SamAccountName
        UserPrincipalName     = $UserPrincipalName
        EmailAddress          = $EmailAddress
        Path                  = $TargetOU
        AccountPassword       = $InitialPassword
        Enabled               = $true
        ChangePasswordAtLogon = $true
    }
    if ($Department) { $newUserParams.Department = $Department }
    if ($Title)      { $newUserParams.Title = $Title }

    if ($PSCmdlet.ShouldProcess($SamAccountName, "New-ADUser")) {
        try {
            New-ADUser @newUserParams
            $newAdUser = Get-ADUser -Identity $SamAccountName -Properties DistinguishedName
            Add-Result "AD" $SamAccountName "New-ADUser" "Success" $TargetOU
        }
        catch {
            Add-Result "AD" $SamAccountName "New-ADUser" "Failed" $_.Exception.Message
            $reportFile = Join-Path $ReportPath "$SamAccountName`_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
            if (-not (Test-Path $ReportPath)) { New-Item -Path $ReportPath -ItemType Directory -Force | Out-Null }
            $results | Export-Csv -Path $reportFile -NoTypeInformation
            throw "Could not create AD user '$SamAccountName' - stopping here since nothing else can proceed without the account. See $reportFile for detail."
        }
    }
}
#endregion

#region 4. Add to local AD groups from the profile
Write-Host "`n--- Local AD group provisioning ---" -ForegroundColor Cyan
if ($CloudOnly) {
    Add-Result "AD-Groups" "n/a" "Add-ADGroupMember" "Skipped" "CloudOnly specified - AD groups assumed already applied to the existing account"
}
elseif ($newAdUser) {
    foreach ($g in $adGroupsFromProfile) {
        if ($PSCmdlet.ShouldProcess($g.Name, "Add-ADGroupMember ($SamAccountName)")) {
            try {
                $targetGroup = $null
                try { $targetGroup = Get-ADGroup -Identity $g.DistinguishedName -ErrorAction Stop }
                catch {
                    # Group may have been renamed/moved since the profile was exported -
                    # fall back to a name-based lookup before giving up on it.
                    $targetGroup = Get-ADGroup -Filter "Name -eq '$($g.Name)'" -ErrorAction SilentlyContinue | Select-Object -First 1
                }
                if (-not $targetGroup) {
                    Add-Result "AD-Groups" $g.Name "Add-ADGroupMember" "Failed" "Group not found by saved DN or by Name - may have been renamed or deleted since the profile was exported"
                    continue
                }
                Add-ADGroupMember -Identity $targetGroup.DistinguishedName -Members $newAdUser.DistinguishedName
                Add-Result "AD-Groups" $g.Name "Add-ADGroupMember" "Success"
            }
            catch {
                Add-Result "AD-Groups" $g.Name "Add-ADGroupMember" "Failed" $_.Exception.Message
            }
        }
    }
}
else {
    Add-Result "AD-Groups" "n/a" "Add-ADGroupMember" "Skipped" "New-ADUser did not run (WhatIf) - nothing to add group memberships to yet"
}
#endregion

#region 5. Trigger / wait for Entra Connect delta sync
if (-not $SkipEntraSyncWait -and $EntraConnectServer) {
    Write-Host "`n--- Triggering Entra Connect delta sync on $EntraConnectServer ---" -ForegroundColor Cyan
    try {
        Invoke-Command -ComputerName $EntraConnectServer -ScriptBlock {
            Import-Module ADSync
            Start-ADSyncSyncCycle -PolicyType Delta
        } -ErrorAction Stop
        Add-Result "Sync" $EntraConnectServer "Start-ADSyncSyncCycle Delta" "Triggered"

        $elapsed = 0
        do {
            Start-Sleep -Seconds 15
            $elapsed += 15
            $syncing = Invoke-Command -ComputerName $EntraConnectServer -ScriptBlock {
                (Get-ADSyncScheduler).SyncCycleInProgress
            }
        } while ($syncing -and $elapsed -lt $SyncWaitTimeoutSeconds)

        if ($syncing) {
            Add-Result "Sync" $EntraConnectServer "Wait for sync completion" "TimedOut" "Exceeded $SyncWaitTimeoutSeconds s; the new user may not be in Entra yet - re-run cloud steps later if step 6 below can't find them"
        }
        else {
            Add-Result "Sync" $EntraConnectServer "Wait for sync completion" "Success" "Completed in ~${elapsed}s"
        }
    }
    catch {
        Add-Result "Sync" $EntraConnectServer "Start-ADSyncSyncCycle Delta" "Failed" $_.Exception.Message
        Write-Warning "Could not trigger/verify Entra Connect sync. The new user may not exist in Entra yet - cloud steps below may fail or need to be re-run once sync completes."
    }
}
else {
    Add-Result "Sync" "n/a" "Entra Connect delta sync" "Skipped" "SkipEntraSyncWait set or no -EntraConnectServer provided"
}
#endregion

#region 6. Connect to Graph, add cloud groups, assign licenses
Write-Host "`n--- Cloud (Entra ID) provisioning ---" -ForegroundColor Cyan
try {
    if (-not (Get-MgContext)) {
        Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "GroupMember.ReadWrite.All", "Directory.Read.All" -NoWelcome
    }

    $mgUser = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'" -Property Id, UserPrincipalName
    if (-not $mgUser) {
        Add-Result "Entra" $UserPrincipalName "Get-MgUser" "Failed" "User not found in Entra ID yet - hybrid sync may not have completed. Re-run once sync catches up; the AD-side work above already completed."
    }
    else {
        # Usage location must be set before Microsoft Graph will allow a license
        # assignment - do this before groups/licenses regardless of whether this
        # particular profile has licenses, since it's cheap and generally useful.
        if ($UsageLocation -and $UsageLocation -notlike "*CHANGE-ME*") {
            if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Set usage location: $UsageLocation")) {
                try {
                    Update-MgUser -UserId $mgUser.Id -UsageLocation $UsageLocation
                    Add-Result "Entra" $UserPrincipalName "Update-MgUser UsageLocation" "Success" $UsageLocation
                }
                catch {
                    Add-Result "Entra" $UserPrincipalName "Update-MgUser UsageLocation" "Failed" $_.Exception.Message
                }
            }
        }
        else {
            Add-Result "Entra" $UserPrincipalName "Update-MgUser UsageLocation" "Skipped" "No usage location resolved - license assignment below will likely fail without one"
        }

        foreach ($g in $entraGroupsFromProfile) {
            if ($g.IsDynamic) {
                Add-Result "Entra-Groups" $g.GroupName "Add member" "Skipped" "Dynamic membership group - can't be manually added. User will only join automatically if they match the group's own rule."
                continue
            }
            if ($g.IsSynced) {
                Add-Result "Entra-Groups" $g.GroupName "Add member" "Info" "Synced group - already added via the matching AD group above; will appear in Entra after the next sync"
                continue
            }
            if ($PSCmdlet.ShouldProcess($g.GroupName, "Add cloud group membership ($UserPrincipalName)")) {
                try {
                    New-MgGroupMemberByRef -GroupId $g.GroupId -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($mgUser.Id)"
                    Add-Result "Entra-Groups" $g.GroupName "New-MgGroupMemberByRef" "Success"
                }
                catch {
                    Add-Result "Entra-Groups" $g.GroupName "New-MgGroupMemberByRef" "Failed" $_.Exception.Message
                }
            }
        }

        if ($licensesFromProfile.Count -gt 0) {
            Ensure-Module -Name 'Microsoft.Graph.Users.Actions' -ManualInstallHint "Install-Module Microsoft.Graph.Users.Actions -Scope CurrentUser"
            foreach ($lic in $licensesFromProfile) {
                if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Assign license: $($lic.SkuPartNumber)")) {
                    try {
                        Set-MgUserLicense -UserId $mgUser.Id -AddLicenses @(@{ SkuId = $lic.SkuId }) -RemoveLicenses @() | Out-Null
                        Add-Result "Entra-Licenses" $lic.SkuPartNumber "Set-MgUserLicense (add)" "Success"
                    }
                    catch {
                        Add-Result "Entra-Licenses" $lic.SkuPartNumber "Set-MgUserLicense (add)" "Failed" $_.Exception.Message
                    }
                }
            }
        }
    }
}
catch {
    Add-Result "Entra" $UserPrincipalName "Graph provisioning" "Failed" $_.Exception.Message
}
#endregion

#region 7. Report
if (-not (Test-Path $ReportPath)) {
    New-Item -Path $ReportPath -ItemType Directory -Force | Out-Null
}
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

if ($passwordWasGenerated) {
    Write-Host "`n=====================================================================" -ForegroundColor Yellow
    Write-Host " TEMPORARY PASSWORD (shown once, not saved anywhere by this script):" -ForegroundColor Yellow
    Write-Host " $plainPassword" -ForegroundColor Yellow
    Write-Host " Copy this now. The account requires a password change at next logon." -ForegroundColor Yellow
    Write-Host "=====================================================================" -ForegroundColor Yellow
}
#endregion
