#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a new on-prem AD user and provisions them with the same local AD groups,
    Entra ID groups, and Entra ID licenses captured in a JSON access profile produced by
    Export-UserAccessProfile.ps1.

.DESCRIPTION
    THIS IS THE VENDOR-NEUTRAL VARIANT. Environment defaults are read from environment.psd1 beside this script - copy environment.example.psd1 and fill it in before first use. Every value there is a default; the equivalent parameter always wins.

    Pipeline:
      1. If -SamAccountName wasn't given, generate one from -GivenName/-Surname as
         first-initial + surname, lowercased (John Smith -> jsmith), appending an
         incrementing number on collision (jsmith2, jsmith3, ...). DisplayName, GivenName
         and Surname keep their original casing - only the account identifiers are
         lowercased.
      2. Load the JSON access profile from -ProfilePath (see Export-UserAccessProfile-
         the organization.ps1 to create one from a template user). Resolve -TargetOU and the
         UPN domain: explicit param > the profile's own values > section 0 fallback.
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
    Which access profile to provision from. Optional. Accepts a full path, a path relative
    to the package, or just the profile's name (-ProfilePath Sales-Engineering resolves to
    AccessProfiles\Sales-Engineering.json). Omit it entirely in an interactive session and
    you get a numbered menu of every profile in AccessProfiles\, showing each one's
    department, template user, group/license counts and export date. In a non-interactive
    session, omitting it is an error that lists the available profiles rather than a hang.

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
    "0. Configuration" suffix only if the profile doesn't have that. Lowercased either way -
    both the local part and the suffix.

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
    template user's own); falls back to the section "0. Configuration" default ("US" for
    the organization) only if the profile doesn't have that value.

.PARAMETER Department
    Optional AD "Department" attribute to set on the new user.

.PARAMETER Title
    Optional AD "Title" attribute to set on the new user.

.PARAMETER InitialPassword
    Temporary password for the new account, as a SecureString. If omitted, a random
    16-character complex password is generated and shown once in the console (see the
    SECURITY NOTE above) - the account is created with -ChangePasswordAtLogon, so this
    is only ever meant to be used once.

.PARAMETER UsageLocationAdAttribute
    Name of the AD attribute that Entra Connect flows into usageLocation, e.g.
    msExchUsageLocation. Supply this and the script writes the usage location to that AD
    attribute as well as to Entra, so the value survives the next sync cycle instead of
    being overwritten by an empty AD value.

    NO DEFAULT, deliberately. Which attribute (if any) feeds usageLocation depends entirely
    on this tenant's Entra Connect sync rules, and writing to the wrong one - or one whose
    LDAP syntax isn't a string - achieves nothing or errors. Region 6b prints the correct
    attribute name for this environment; pass it here once you know it. If the write fails
    because the attribute doesn't exist or won't accept the value, it's reported and the run
    continues - the cloud-side value is still set.

.PARAMETER CheckUsageLocationSyncRules
    Attempt the Entra Connect sync-rule ownership check over PowerShell remoting. Off by
    default because it cannot work: the ADSync management cmdlets use a named-pipe WCF
    endpoint that remoting can't reach, so it fails with "no endpoint listening at
    net.pipe://localhost/ADSyncManagement" while the delta sync on the same connection
    succeeds. Run Test-UsageLocationSyncRules.ps1 locally on the sync server instead. The
    switch exists for an environment where that endpoint is reachable.

.PARAMETER EntraConnectServer
    Hostname of the Entra Connect / AD Connect server, used to remotely trigger
    Start-ADSyncSyncCycle over PowerShell remoting. Defaults to
    $Script:DefaultEntraConnectServer in section 0 (the the organization preset, same value the
    offboarding script uses). Pass -SkipEntraSyncWait if you trigger sync another way.

.PARAMETER SkipEntraSyncWait
    Skip triggering/waiting on an Entra Connect delta sync before the cloud steps run.
    Only use this if you already know a sync has run very recently, otherwise the new
    user may not exist in Entra yet when step 5 looks for them.

.PARAMETER SyncWaitTimeoutSeconds
    Max seconds to wait for the triggered sync to finish. Defaults to 300 (5 minutes).

.PARAMETER EntraLookupTimeoutSeconds
    How long to keep polling Entra ID for the newly created user before giving up, in
    seconds. Defaults to 300 (5 minutes), checked every 15.

    A completed sync cycle does not mean the object is queryable yet: Entra Connect exports
    it, then Entra processes the write, and the two are not simultaneous. A single lookup
    immediately after the sync will often miss - and missing it means every cloud step
    (usage location, cloud-only groups, licenses) is skipped for that run.

.PARAMETER ReportPath
    Folder to write the per-run CSV report to. Defaults to a fixed, shared location:
    a Reports\ProvisioningReports subfolder inside this script's own package folder
    (resolved via $PSScriptRoot, so the package is portable) - not a relative ".\..." path, so reports always
    land in the same findable spot no matter what directory PowerShell happens to be in
    when you run this (e.g. C:\Windows\System32, which is where this ends up if launched
    from a shortcut/Run box without changing directory first).

.PARAMETER AutoInstallMissingModules
    If a required PSGallery module isn't installed, install it automatically for the
    current user instead of prompting. The ActiveDirectory module (RSAT) can never be
    auto-installed this way - see .NOTES.

.PARAMETER WhatIf
    Standard ShouldProcess support - preview every change without making it. Note the
    account-existence and OU checks still run for real, since they're read-only.

.EXAMPLE
    .\New-UserFromAccessProfile.ps1 -ProfilePath .\AccessProfiles\Engineering-NewHire.json -GivenName John -Surname Smith -EntraConnectServer AADC01
    (No -SamAccountName given - generates "jsmith", or "jsmith2" etc. if that's taken.)

.EXAMPLE
    .\New-UserFromAccessProfile.ps1 -ProfilePath .\AccessProfiles\Engineering-NewHire.json -SamAccountName jdoe2 -GivenName Jane -Surname Doe -WhatIf
    (Explicit -SamAccountName overrides the generated name.)

.EXAMPLE
    .\New-UserFromAccessProfile.ps1 -ProfilePath .\AccessProfiles\Engineering-NewHire.json -SamAccountName KLee -CloudOnly
    (AD account "KLee" already exists from a prior run - skips AD creation/groups and
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

    ENTRA CONNECT SERVER (only needed if you want this script to trigger a sync)
      - Hostname of whichever server has Microsoft Entra Connect (formerly Azure AD
        Connect) installed. Confirm you have the right box by running, ON that server:
        Get-ADSyncScheduler
      - If you don't know it or don't want to grant remoting rights to it, omit
        -EntraConnectServer; the script still works, it just won't trigger a sync itself,
        and cloud group/license steps may need to be re-run later once sync catches up.

    Run this from an admin workstation with the ActiveDirectory RSAT module installed,
    or from a domain controller. Exchange Online / Graph connections happen over the
    internet regardless of where the script runs.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
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

    [string]$UsageLocationAdAttribute,

    [switch]$CheckUsageLocationSyncRules,

    [string]$EntraConnectServer,

    [switch]$SkipEntraSyncWait,

    [int]$SyncWaitTimeoutSeconds = 300,

    [int]$EntraLookupTimeoutSeconds = 300,

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
if (-not $ReportPath) { $ReportPath = Join-Path $Script:PackageRoot 'Reports\ProvisioningReports' }
$Script:AccessProfileDir = Join-Path $Script:PackageRoot 'AccessProfiles'
# ---------------------------------------------------------------------------------------


#region 0. Configuration (the organization preset)
# ---------------------------------------------------------------------------------------
# These are LAST-RESORT fallbacks only. -TargetOU, the UPN domain, and UsageLocation
# normally come from the access profile itself (the template user's own OU, email domain,
# and usage location - see section 1b below), so most runs won't need any of these set.
# They only kick in if you pass a param explicitly AND the profile is missing that data
# (e.g. an older profile exported before this script tracked it), or as a last fallback if
# neither is available. DefaultUsageLocation is set to "US" for the organization; Graph won't
# assign a license to a user without a usage location set.
# ---------------------------------------------------------------------------------------

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

$Script:DefaultNewUserOU = Get-EnvSetting -Name 'NewUserOU'
$Script:DefaultUpnSuffix = Get-EnvSetting -Name 'UpnSuffix'

# Bump on any behaviour change. Logged as the first row of every report, so a saved CSV maps
# to a known build - and so "which version is on the share?" is answerable at a glance:
#   Select-String -Path .\New-UserFromAccessProfile.ps1 -Pattern 'ScriptVersion ='
$Script:ScriptVersion = "2026-09-09.1 (SamAccountName/UPN/mail forced to lowercase at every entry point - generated, explicit, and profile-derived; display name attributes unchanged; Graph module version preflight; Graph conflict diagnosis; UPN suffix lowercased + verified; sync-cycle start/finish wait; Entra lookup polling; usage-location read-back and sync-rule check; pre-license guard; -WhatIf no longer triggers a sync, polls for an uncreated account, prints a password for an account that does not exist, or claims a report it did not write; preview now names the AD groups it would add; suppressed leaked Start-ADSyncSyncCycle output; sync-rule probe moved to Test-UsageLocationSyncRules.ps1 for local execution, since remoting cannot reach the ADSync named pipe)"
$Script:DefaultUsageLocation = Get-EnvSetting -Name 'UsageLocation'
# Entra Connect / AD Connect server, used to trigger a delta sync so the new AD account
# and its group memberships reach Entra before the cloud steps run. Matches the same
# default in Offboard-HybridUser.ps1. Pass -SkipEntraSyncWait to opt out, or
# -EntraConnectServer <name> to override.
$Script:DefaultEntraConnectServer = Get-EnvSetting -Name 'EntraConnectServer'
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

Add-Result "Meta" "ScriptVersion" "Run started" "Info" $Script:ScriptVersion

# Ensures a required module is available, importing it if present, offering to install it
# if it's missing and comes from PSGallery, or explaining how to get it if it doesn't
# (currently only ActiveDirectory/RSAT, which is a Windows feature, not a gallery module).
# Multiple installed versions of the same Microsoft.Graph submodule are the usual cause of
# "Assembly with same name is already loaded" partway through a run: PowerShell resolves each
# import to the HIGHEST installed version, so importing a module that exists at 2.38.1 pins
# that Authentication assembly - and any submodule that only exists at 2.38.0 can then never
# load. Detect it up front rather than failing halfway through, with AD changes already made.
function Test-GraphModuleVersions {
    $dupes = @(Get-Module Microsoft.Graph* -ListAvailable |
               Group-Object Name |
               Where-Object { @($_.Group.Version | Sort-Object -Unique).Count -gt 1 })
    if ($dupes.Count -eq 0) {
        Add-Result "Meta" "Microsoft.Graph modules" "Version consistency" "Success" "One version installed per module"
        return
    }

    Write-Warning "$($dupes.Count) Microsoft.Graph module(s) have more than one version installed. This usually causes an assembly conflict partway through the run."
    foreach ($d in $dupes) {
        $vers = @($d.Group.Version | Sort-Object -Unique) -join ', '
        Write-Host ("    {0,-50} {1}" -f $d.Name, $vers) -ForegroundColor DarkYellow
    }
    Write-Host "  Keep ONE version per module. Check which versions the whole suite has:" -ForegroundColor DarkYellow
    Write-Host "    Get-Module Microsoft.Graph* -ListAvailable | Select Name,Version | Sort Name,Version" -ForegroundColor DarkYellow
    Write-Host "  then remove the odd ones out, in a session with no Graph modules loaded:" -ForegroundColor DarkYellow
    Write-Host "    Uninstall-Module <name> -RequiredVersion <version> -Force" -ForegroundColor DarkYellow

    Add-Result "Meta" "Microsoft.Graph modules" "Version consistency" "Warning" (
        "$($dupes.Count) module(s) have multiple versions installed: " +
        (($dupes | ForEach-Object { "$($_.Name) [$((@($_.Group.Version | Sort-Object -Unique)) -join '/')]" }) -join '; ') +
        ". PowerShell resolves each import to the highest version, so a submodule that only exists at the lower " +
        "version cannot load its matching Authentication assembly. Remove the duplicates, keeping the version " +
        "that the whole suite has.")
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

# Derives a SamAccountName from first-initial + surname (John Smith -> jsmith) when
# -SamAccountName isn't supplied. Checks AD for a collision and appends an incrementing
# number (jsmith2, jsmith3, ...) until it finds one that's free, respecting the 20-char
# SamAccountName limit.
#
# The name is lowercased HERE, at the single point of generation, so every downstream
# consumer inherits it: the UPN local part, the mail attribute, and the report filename are
# all built from this return value. ToLowerInvariant rather than ToLower - ToLower() honours
# the current culture, and under a tr-TR locale 'I' maps to dotless 'i', which would quietly
# produce an account name nobody can type. Casing is applied before the collision loop
# because the loop only ever appends digits, so an all-lowercase base stays all-lowercase.
function New-UniqueSamAccountName {
    param(
        [Parameter(Mandatory)] [string]$GivenName,
        [Parameter(Mandatory)] [string]$Surname
    )
    $baseName = (("{0}{1}" -f $GivenName.Substring(0, 1), $Surname) -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
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


#region 0b. Pick the access profile
# ---------------------------------------------------------------------------------------
# -ProfilePath is optional. Omitted in an interactive session, this lists every profile in
# AccessProfiles\ as a numbered menu, so a department/role profile can be chosen by name
# without anyone typing a path. A bare name still works too (-ProfilePath Sales-Engineering),
# and in a non-interactive session a missing -ProfilePath is a hard error listing what's
# available rather than a hang on a prompt.
# ---------------------------------------------------------------------------------------

# Reads the profiles on disk into a display list. Bad JSON is surfaced, not silently hidden,
# so a corrupt profile is obvious in the menu rather than just absent from it.
function Get-AccessProfileInventory {
    if (-not (Test-Path $Script:AccessProfileDir)) { return @() }
    $items = New-Object System.Collections.Generic.List[Object]
    foreach ($f in (Get-ChildItem $Script:AccessProfileDir -Filter *.json -File | Sort-Object Name)) {
        $row = [ordered]@{
            File     = $f.FullName
            BaseName = $f.BaseName
            Name     = $f.BaseName
            Dept     = ''
            Source   = ''
            Exported = ''
            AD       = 0
            Entra    = 0
            Lic      = 0
            Valid    = $true
        }
        try {
            $d = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            if ($d.ProfileName)   { $row.Name     = $d.ProfileName }
            if ($d.SourceDept)    { $row.Dept     = $d.SourceDept }
            if ($d.SourceUser)    { $row.Source   = $d.SourceUser }
            if ($d.ExportedDate)  { $row.Exported = $d.ExportedDate }
            $row.AD    = @($d.ADGroups).Count
            $row.Entra = @($d.EntraGroups).Count
            $row.Lic   = @($d.Licenses).Count
        }
        catch { $row.Valid = $false }
        $items.Add([PSCustomObject]$row)
    }
    return $items
}

function Show-AccessProfileMenu {
    $inv = @(Get-AccessProfileInventory)
    if ($inv.Count -eq 0) {
        throw ("No access profiles found in $Script:AccessProfileDir. Create one first: " +
               ".\Export-UserAccessProfile.ps1 -SamAccountName <template user> " +
               "-ProfileName '<Department or role>'")
    }

    Write-Host ""
    Write-Host "  Access profiles in $Script:AccessProfileDir" -ForegroundColor Cyan
    Write-Host "  ---------------------------------------------------------------------------"
    for ($i = 0; $i -lt $inv.Count; $i++) {
        $p = $inv[$i]
        if (-not $p.Valid) {
            Write-Host ("   {0,2})  {1}" -f ($i + 1), $p.BaseName) -ForegroundColor DarkYellow -NoNewline
            Write-Host "   [unreadable JSON - cannot be used]" -ForegroundColor Red
            continue
        }
        Write-Host ("   {0,2})  {1}" -f ($i + 1), $p.Name) -ForegroundColor White
        $meta = @()
        if ($p.Dept)   { $meta += "dept: $($p.Dept)" }
        if ($p.Source) { $meta += "from: $($p.Source)" }
        $meta += "AD $($p.AD) / Entra $($p.Entra) / lic $($p.Lic)"
        if ($p.Exported) { $meta += "exported $($p.Exported)" }
        Write-Host ("        " + ($meta -join '  |  ')) -ForegroundColor DarkGray
    }
    Write-Host "  ---------------------------------------------------------------------------"
    Write-Host "    0)  Cancel" -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        $answer = Read-Host "  Profile number"
        if ($answer -eq '0') { return $null }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $inv.Count) {
            $chosen = $inv[$n - 1]
            if (-not $chosen.Valid) {
                Write-Host "  That profile's JSON can't be parsed - pick another, or re-export it." -ForegroundColor Red
                continue
            }
            Write-Host "  Selected: $($chosen.Name)" -ForegroundColor Green
            return $chosen.File
        }
        Write-Host "  Enter a number between 1 and $($inv.Count), or 0 to cancel." -ForegroundColor Yellow
    }
}

if (-not $ProfilePath) {
    if ([Environment]::UserInteractive -and $Host.Name -ne 'Default Host') {
        $ProfilePath = Show-AccessProfileMenu
        if (-not $ProfilePath) {
            Write-Host "Cancelled at the profile menu - nothing was created." -ForegroundColor Yellow
            return
        }
    }
    else {
        $available = @(Get-AccessProfileInventory | Where-Object Valid | Select-Object -ExpandProperty BaseName)
        $msg = "-ProfilePath is required in a non-interactive session."
        if ($available.Count -gt 0) {
            $msg += "`nAvailable profiles in $Script:AccessProfileDir :`n  " + ($available -join "`n  ")
            $msg += "`nPass one by name, e.g. -ProfilePath '$($available[0])'"
        }
        else {
            $msg += "`nNo profiles found in $Script:AccessProfileDir - create one first with Export-UserAccessProfile."
        }
        throw $msg
    }
}
#endregion

Write-Host "=== Provisioning new user from profile: $ProfilePath ===" -ForegroundColor Cyan

#region 1. Load / verify modules
Ensure-Module -Name 'ActiveDirectory' -IsWindowsFeature -ManualInstallHint (
    "Windows 10/11: Settings > Optional Features > Add a feature > 'RSAT: Active Directory " +
    "Domain Services and Lightweight Directory Tools' (or run, as admin: " +
    "Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0). " +
    "Windows Server: Install-WindowsFeature RSAT-AD-PowerShell."
)
Test-GraphModuleVersions

Ensure-Module -Name 'Microsoft.Graph.Users' -ManualInstallHint "Install-Module Microsoft.Graph.Users -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Groups' -ManualInstallHint "Install-Module Microsoft.Graph.Groups -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Identity.DirectoryManagement' -ManualInstallHint "Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser"
#endregion

if (-not $EntraConnectServer) { $EntraConnectServer = $Script:DefaultEntraConnectServer }

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
    # Prompt rather than throw when run interactively with no name args - the profile
     # menu above already established this is a hands-on run.
    if ((-not $GivenName -or -not $Surname) -and [Environment]::UserInteractive -and $Host.Name -ne 'Default Host') {
        Write-Host ""
        Write-Host "  New hire's name" -ForegroundColor Cyan
        if (-not $GivenName) { $GivenName = (Read-Host "  First name").Trim() }
        if (-not $Surname)   { $Surname   = (Read-Host "  Last name").Trim() }
    }
    if (-not $GivenName -or -not $Surname) {
        throw "-GivenName and -Surname are required unless -CloudOnly is specified."
    }
    if (-not $SamAccountName) {
        $SamAccountName = New-UniqueSamAccountName -GivenName $GivenName -Surname $Surname
        Write-Host "No -SamAccountName given - generated '$SamAccountName' from $GivenName $Surname (first initial + surname, incrementing on collision)."
    }
    elseif ($SamAccountName -cne $SamAccountName.ToLowerInvariant()) {
        # Normalised on the explicit route too, so the two paths into this variable cannot
        # disagree about casing. Only applies when creating - under -CloudOnly the account
        # already exists and its stored casing is left exactly as it is.
        Write-Host "Lowercasing -SamAccountName '$SamAccountName' -> '$($SamAccountName.ToLowerInvariant())' to match generated names."
        $SamAccountName = $SamAccountName.ToLowerInvariant()
    }
}
Write-Host ("=== Provisioning $SamAccountName" + $(if ($CloudOnly) { " (cloud-only - existing AD account)" }) + " ===") -ForegroundColor Cyan
#endregion

#region 1b. Load the access profile
# Accept a bare profile name as well as a path: "-ProfilePath Engineering" resolves to
# <package>\AccessProfiles\Engineering.json. This is what lets the export/provision pair
# work by role name without anyone typing absolute paths.
if (-not (Test-Path $ProfilePath)) {
    $accessProfileDir = $Script:AccessProfileDir
    foreach ($candidate in @(
        (Join-Path $accessProfileDir $ProfilePath),
        (Join-Path $accessProfileDir "$ProfilePath.json")
    )) {
        if (Test-Path $candidate) {
            Write-Host "Resolved profile '$ProfilePath' to $candidate" -ForegroundColor DarkCyan
            $ProfilePath = $candidate
            break
        }
    }
}
if (-not (Test-Path $ProfilePath)) {
    $accessProfileDir = $Script:AccessProfileDir
    $available = @()
    if (Test-Path $accessProfileDir) {
        $available = Get-ChildItem $accessProfileDir -Filter *.json -ErrorAction SilentlyContinue |
                     Select-Object -ExpandProperty BaseName
    }
    $msg = "Access profile not found: $ProfilePath"
    if ($available.Count -gt 0) {
        $msg += "`nAvailable profiles in $accessProfileDir :`n  " + ($available -join "`n  ")
        $msg += "`nPass one by name, e.g. -ProfilePath '$($available[0])'"
    }
    else {
        $msg += "`nNo profiles found in $accessProfileDir - create one first with Export-UserAccessProfile."
    }
    throw $msg
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
    # template user's OU - a new hire cloned from this profile normally belongs there
    # too), then the section 0 fallback as a last resort.
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

    # Resolve the UPN domain the same way: explicit -UserPrincipalName wins, then the
    # domain portion of the profile's SourceUser UPN, then the section 0 fallback suffix.
    #
    # The suffix is forced to LOWERCASE. Profiles carry whatever casing the template user's
    # own UPN had - typically 'contoso.com' - and while DNS and authentication treat a
    # domain case-insensitively, the Entra portal matches the stored suffix against its list
    # of verified domains as a plain string. Those are all lowercase, so a mixed-case suffix
    # authenticates perfectly and still shows an EMPTY domain dropdown on the user's Identity
    # blade, which looks like the UPN was never set. The section 0 fallback was already
    # lowercase, which is why the fallback path never showed this and the profile path did.
    if (-not $UserPrincipalName) {
        if ($profileData.SourceUser -and $profileData.SourceUser -match '@') {
            $upnSuffix = $profileData.SourceUser.Split('@')[1].ToLowerInvariant()
            $UserPrincipalName = "$SamAccountName@$upnSuffix"
            Write-Host "Using UPN domain from profile (template user's own domain, lowercased): @$upnSuffix"
        }
        else {
            $UserPrincipalName = "$SamAccountName@$($Script:DefaultUpnSuffix.ToLowerInvariant())"
        }
    }
    elseif ($UserPrincipalName -match '@') {
        # Same treatment for an explicitly passed UPN, so every route produces a suffix the
        # portal can match.
        # Whole string, not just the suffix. The suffix has to be lowercase for the portal
        # to match it against the verified-domain list; the local part is lowercased for
        # consistency with the generated route above, so a hand-passed UPN and a generated
        # one look identical on the account.
        $lowered = $UserPrincipalName.ToLowerInvariant()
        if ($lowered -cne $UserPrincipalName) {
            Write-Host "Lowercasing the UPN so the domain matches Entra and the sign-in name is uniform: $lowered"
            $UserPrincipalName = $lowered
        }
    }
}
if (-not $EmailAddress) {
    $EmailAddress = $UserPrincipalName
}
elseif ($EmailAddress -cne $EmailAddress.ToLowerInvariant()) {
    Write-Host "Lowercasing -EmailAddress: $($EmailAddress.ToLowerInvariant())"
    $EmailAddress = $EmailAddress.ToLowerInvariant()
}

# UPN suffix preflight. New-ADUser accepts ANY string as a UPN suffix - it does not check
# the suffix is registered in the forest - so a typo'd or unregistered domain produces an
# account that looks fine in AD and then behaves oddly in Entra. Report it here rather than
# discovering it in the portal later. Non-fatal: an unregistered suffix can still be correct
# if it's a verified tenant domain and Entra Connect is configured for it.
if ($UserPrincipalName -match '@') {
    $resolvedSuffix = $UserPrincipalName.Split('@')[1]
    try {
        $validSuffixes = @()
        $forest = Get-ADForest -ErrorAction Stop
        $validSuffixes += @($forest.UPNSuffixes)
        foreach ($d in @($forest.Domains)) { $validSuffixes += $d }
        $validSuffixes = @($validSuffixes | Where-Object { $_ } | Sort-Object -Unique)

        if ($validSuffixes -contains $resolvedSuffix) {
            Add-Result "AD" $SamAccountName "UPN suffix check" "Success" "'@$resolvedSuffix' is a registered UPN suffix in this forest"
        }
        else {
            Add-Result "AD" $SamAccountName "UPN suffix check" "Warning" (
                "'@$resolvedSuffix' is NOT a registered UPN suffix in this forest. Registered: " +
                ($validSuffixes -join ', ') + ". AD will still accept it, but if it is also not a VERIFIED domain in " +
                "the tenant, Entra Connect replaces the UPN with <alias>@<tenant>.onmicrosoft.com, and the portal " +
                "shows a blank domain because the user's suffix isn't in its verified-domain list. " +
                "Add the suffix in AD Domains and Trusts, or pass -UserPrincipalName explicitly.")
            Write-Warning "UPN suffix '@$resolvedSuffix' is not registered in this forest (registered: $($validSuffixes -join ', ')). Continuing - see the report."
        }
    }
    catch {
        Add-Result "AD" $SamAccountName "UPN suffix check" "Skipped" "Could not read forest UPN suffixes: $($_.Exception.Message)"
    }
}

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
        Write-Host "Profile has no UsageLocation (older profile, or template user had none set) - falling back to the section 0 default: $UsageLocation"
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
            # Read the UPN back rather than reporting the value we intended to set. These two
            # can differ, and a wrong UPN is invisible until someone opens the user in Entra.
            $newAdUser = Get-ADUser -Identity $SamAccountName -Properties DistinguishedName, UserPrincipalName, mail
            Add-Result "AD" $SamAccountName "New-ADUser" "Success" $TargetOU
            if ($newAdUser.UserPrincipalName -eq $UserPrincipalName) {
                Add-Result "AD" $SamAccountName "UPN written to AD" "Success" "$($newAdUser.UserPrincipalName) - confirmed by read-back"
            }
            else {
                Add-Result "AD" $SamAccountName "UPN written to AD" "Warning" (
                    "Intended '$UserPrincipalName' but AD holds '$($newAdUser.UserPrincipalName)'.")
                Write-Warning "AD UPN mismatch: intended '$UserPrincipalName', AD holds '$($newAdUser.UserPrincipalName)'."
            }
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
    # Name the groups rather than just saying "skipped". The point of a preview is to see the
    # intended changes, and a bare Skipped row tells the operator nothing about what this
    # profile would actually apply.
    Add-Result "AD-Groups" "n/a" "Add-ADGroupMember" "Skipped" (
        "New-ADUser did not run (-WhatIf) - nothing to add group memberships to yet. Would have added: " +
        (@($adGroupsFromProfile | ForEach-Object { $_.Name }) -join ', '))
    if ($adGroupsFromProfile.Count -gt 0) {
        Write-Host "  Would add to $($adGroupsFromProfile.Count) AD group(s):" -ForegroundColor DarkGray
        foreach ($g in $adGroupsFromProfile) { Write-Host "    - $($g.Name)" -ForegroundColor DarkGray }
    }
}
#endregion

#region 5. Trigger / wait for Entra Connect delta sync
# ShouldProcess-guarded: a delta sync is harmless in itself, but firing one during a -WhatIf
# preview contradicts what -WhatIf promises, and then makes the operator wait for it.
if (-not $SkipEntraSyncWait -and $EntraConnectServer -and
    $PSCmdlet.ShouldProcess($EntraConnectServer, "Trigger Entra Connect delta sync and wait for it")) {
    Write-Host "`n--- Triggering Entra Connect delta sync on $EntraConnectServer ---" -ForegroundColor Cyan
    try {
        # Out-Null: Start-ADSyncSyncCycle returns a result object, and over Invoke-Command it
        # arrives decorated with PSComputerName/RunspaceId. Unsuppressed it lands in the
        # output stream and PowerShell renders it wherever the pipeline flushes - which turned
        # out to be directly under the "=== Summary ===" header, looking like part of the report.
        Invoke-Command -ComputerName $EntraConnectServer -ScriptBlock {
            Import-Module ADSync
            Start-ADSyncSyncCycle -PolicyType Delta
        } -ErrorAction Stop | Out-Null
        Add-Result "Sync" $EntraConnectServer "Start-ADSyncSyncCycle Delta" "Triggered"

        # Start-ADSyncSyncCycle is ASYNCHRONOUS - it queues the cycle and returns "Success"
        # immediately. So polling SyncCycleInProgress straight away can see $false because
        # the cycle has not STARTED yet, not because it finished. The previous version slept
        # 15s, saw $false, and reported "Completed in ~15s" for a sync that had barely begun -
        # which is how a brand-new user ends up not yet in Entra when the cloud steps run.
        # Two phases: wait for it to start, then wait for it to finish.
        $Script:GetSyncing = {
            Invoke-Command -ComputerName $EntraConnectServer -ScriptBlock {
                (Get-ADSyncScheduler).SyncCycleInProgress
            }
        }

        $startWait = 0
        do {
            Start-Sleep -Seconds 3
            $startWait += 3
            $syncing = & $Script:GetSyncing
        } while (-not $syncing -and $startWait -lt 45)

        if (-not $syncing) {
            # Either it began and ended inside a 3s window - implausible for an object add -
            # or the scheduler never picked it up. Either way, don't claim it completed.
            Add-Result "Sync" $EntraConnectServer "Wait for sync completion" "Warning" (
                "SyncCycleInProgress never became true within ${startWait}s of triggering, so completion could not be confirmed. " +
                "The cycle may still be queued. The Entra lookup below polls for up to $EntraLookupTimeoutSeconds s, which normally covers this.")
            Write-Host "  Sync cycle didn't report as running within ${startWait}s - continuing; the Entra lookup below will poll." -ForegroundColor DarkYellow
        }
        else {
            Write-Host "  Sync cycle running (detected after ${startWait}s) - waiting for it to finish..." -ForegroundColor DarkCyan
            $elapsed = $startWait
            do {
                Start-Sleep -Seconds 10
                $elapsed += 10
                $syncing = & $Script:GetSyncing
            } while ($syncing -and $elapsed -lt $SyncWaitTimeoutSeconds)

            if ($syncing) {
                Add-Result "Sync" $EntraConnectServer "Wait for sync completion" "TimedOut" "Exceeded $SyncWaitTimeoutSeconds s; the new user may not be in Entra yet - the lookup below polls for up to $EntraLookupTimeoutSeconds s"
            }
            else {
                Add-Result "Sync" $EntraConnectServer "Wait for sync completion" "Success" (
                    "Cycle observed running and then finished, ~${elapsed}s total. Note: export completing is not the same as the object being queryable in Entra - the lookup below polls for that separately.")
            }
        }
    }
    catch {
        Add-Result "Sync" $EntraConnectServer "Start-ADSyncSyncCycle Delta" "Failed" $_.Exception.Message
        Write-Warning "Could not trigger/verify Entra Connect sync. The new user may not exist in Entra yet - cloud steps below may fail or need to be re-run once sync completes."
    }
}
elseif (-not $SkipEntraSyncWait -and $EntraConnectServer) {
    Add-Result "Sync" $EntraConnectServer "Entra Connect delta sync" "Skipped" "-WhatIf - no sync was triggered"
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

    # -UserId (a direct GET) rather than -Filter, for two reasons. An OData $filter is
    # served by a search index that lags the directory, so a freshly synced object can be
    # absent from a filter result while a direct GET already returns it. And a filter
    # breaks on apostrophe surnames (o'brien@...). The offboarding script already does it
    # this way; this one didn't.
    #
    # And poll rather than asking once. A finished sync cycle does not mean the object is
    # queryable: Entra Connect exports it, then Entra processes the write. A single lookup
    # here previously abandoned ALL cloud provisioning - usage location, cloud-only groups
    # and every license - on one miss, while the AD half looked completely clean.
    $mgUser = $null
    $lookupElapsed = 0

    # In a -WhatIf run New-ADUser never executed, so $newAdUser is null and there is no
    # object in Entra to find. Polling for it would burn the full timeout waiting for
    # something we deliberately didn't create, which makes a preview look like a hang.
    $noAccountToFind = (-not $CloudOnly) -and (-not $newAdUser)

    if ($noAccountToFind) {
        Add-Result "Entra" $UserPrincipalName "Get-MgUser" "Skipped" (
            "No AD account was created (-WhatIf), so there is nothing in Entra to look up. All cloud steps skipped - expected in a preview.")
        Write-Host "  -WhatIf: no account was created, so the cloud steps are skipped (nothing to look up)." -ForegroundColor DarkYellow
    }
    else {
        while ($true) {
            try {
                $mgUser = Get-MgUser -UserId $UserPrincipalName -Property Id, UserPrincipalName, UsageLocation, OnPremisesSyncEnabled -ErrorAction Stop
            }
            catch {
                $mgUser = $null
            }
            if ($mgUser) { break }
            if ($lookupElapsed -ge $EntraLookupTimeoutSeconds) { break }
            Write-Host "  Not in Entra ID yet - waiting 15s (${lookupElapsed}s of ${EntraLookupTimeoutSeconds}s)..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 15
            $lookupElapsed += 15
        }

        if (-not $mgUser) {
            Add-Result "Entra" $UserPrincipalName "Get-MgUser" "Failed" (
                "Not found in Entra ID after polling for ${lookupElapsed}s. EVERY cloud step was skipped: usage location, " +
                "cloud-only groups and all licenses. The AD account and its AD groups are fine. " +
                "Finish the cloud half with: .\New-UserFromAccessProfile.ps1 -ProfilePath '$ProfilePath' -SamAccountName $SamAccountName -CloudOnly")
        }
        elseif ($lookupElapsed -gt 0) {
            Add-Result "Entra" $UserPrincipalName "Get-MgUser" "Success" "Found after polling for ${lookupElapsed}s - a single immediate lookup would have missed it"
        }
    }

    # A UserPrincipalName in Entra that differs from OnPremisesUserPrincipalName is the exact
    # signature of Entra Connect substituting the suffix, which it does when the on-prem
    # suffix is not a verified domain in the tenant. That substitution is silent: AD keeps
    # the suffix you set, Entra shows something else, and the portal's domain dropdown reads
    # blank because the stored suffix isn't in its verified-domain list.
    if ($mgUser) {
        try {
            $upnCheck = Get-MgUser -UserId $mgUser.Id -Property Id, UserPrincipalName, OnPremisesUserPrincipalName, OnPremisesSyncEnabled -ErrorAction Stop
            Add-Result "Entra" $UserPrincipalName "UPN in Entra" "Info" (
                "Entra: '$($upnCheck.UserPrincipalName)' | on-prem: '$($upnCheck.OnPremisesUserPrincipalName)'")
            # -cne, case-SENSITIVE. PowerShell's -ne is case-insensitive, so a suffix that
            # differs only in case compares as equal and this whole class of problem would
            # slip past. That casing is precisely what blanks the portal's domain dropdown.
            if ($upnCheck.UserPrincipalName -match '@') {
                $entraSuffix = $upnCheck.UserPrincipalName.Split('@')[1]
                if ($entraSuffix -cne $entraSuffix.ToLowerInvariant()) {
                    Add-Result "Entra" $UserPrincipalName "UPN suffix casing" "Warning" (
                        "Entra stores the suffix as '$entraSuffix', not all-lowercase. Authentication is unaffected, " +
                        "but the portal matches suffixes against its verified-domain list as plain strings - all of " +
                        "which are lowercase - so the Identity blade will show an EMPTY domain dropdown. " +
                        "Fix with: Set-ADUser $SamAccountName -UserPrincipalName '$($upnCheck.UserPrincipalName.Split('@')[0])@$($entraSuffix.ToLowerInvariant())' then re-sync.")
                    Write-Warning "Entra's UPN suffix '$entraSuffix' isn't lowercase - the portal's domain dropdown will read blank."
                }
                else {
                    Add-Result "Entra" $UserPrincipalName "UPN suffix casing" "Success" "'$entraSuffix' is lowercase - the portal will prefill the domain"
                }
            }

            if ($upnCheck.OnPremisesUserPrincipalName -and
                $upnCheck.UserPrincipalName -ne $upnCheck.OnPremisesUserPrincipalName) {
                Add-Result "Entra" $UserPrincipalName "UPN substituted by Entra Connect" "Warning" (
                    "AD holds '$($upnCheck.OnPremisesUserPrincipalName)' but Entra holds '$($upnCheck.UserPrincipalName)'. " +
                    "Entra Connect rewrote the suffix, which it does when the on-prem suffix is not a verified tenant domain. " +
                    "Verify the domain in Entra (Get-MgDomain), then re-sync - correcting it in AD alone will not fix it.")
                Write-Warning "Entra rewrote this user's UPN: AD '$($upnCheck.OnPremisesUserPrincipalName)' -> Entra '$($upnCheck.UserPrincipalName)'."
            }
        }
        catch {
            Add-Result "Entra" $UserPrincipalName "UPN in Entra" "Skipped" $_.Exception.Message
        }
    }
    if ($mgUser) {
        # Usage location must be set before Microsoft Graph will allow a license
        # assignment - do this before groups/licenses regardless of whether this
        # particular profile has licenses, since it's cheap and generally useful.
        #
        # Update-MgUser NOT THROWING IS NOT PROOF THE VALUE STUCK. On a hybrid-synced
        # user, Entra Connect is authoritative for every attribute its sync rules flow.
        # If usageLocation is one of them, the write below succeeds, the licenses a few
        # seconds later assign fine, and then the next sync cycle overwrites the value
        # with whatever AD holds - usually nothing. By the time anyone opens the user in
        # the portal the field is blank while the licenses are still assigned, which is a
        # confusing pair of symptoms to reconcile. So: write it, read it back, and in
        # region 6b ask Entra Connect directly whether it claims the attribute.
        if ($UsageLocation -and $UsageLocation -notlike "*CHANGE-ME*") {
            if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Set usage location: $UsageLocation")) {
                try {
                    Update-MgUser -UserId $mgUser.Id -UsageLocation $UsageLocation
                    Start-Sleep -Seconds 3
                    $ulCheck = Get-MgUser -UserId $mgUser.Id -Property Id, UsageLocation, OnPremisesSyncEnabled -ErrorAction Stop
                    Add-Result "Entra" $UserPrincipalName "OnPremisesSyncEnabled" "Info" (
                        "$($ulCheck.OnPremisesSyncEnabled) - when True, Entra Connect can overwrite any attribute its sync rules flow")
                    if ($ulCheck.UsageLocation -eq $UsageLocation) {
                        Add-Result "Entra" $UserPrincipalName "Update-MgUser UsageLocation" "Success" "$UsageLocation - confirmed by read-back"
                    }
                    else {
                        Add-Result "Entra" $UserPrincipalName "Update-MgUser UsageLocation" "Failed" (
                            "Wrote '$UsageLocation' but the read-back returned '$($ulCheck.UsageLocation)'. " +
                            "The write was rejected or immediately reverted - see the sync-rule check below. " +
                            "License assignment further down will probably fail too.")
                        Write-Warning "Usage location did not stick: wrote '$UsageLocation', read back '$($ulCheck.UsageLocation)'."
                    }
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

        # Usage location is a hard prerequisite: Graph refuses a license assignment without
        # one. So re-read it immediately before assigning rather than trusting the write
        # further up - groups were processed in between, and on a synced user a sync cycle
        # can land in that window and blank it. Checking once here is far better than N
        # opaque per-SKU Graph failures.
        if ($licensesFromProfile.Count -gt 0) {
            $ulNow = $null
            try { $ulNow = (Get-MgUser -UserId $mgUser.Id -Property Id, UsageLocation -ErrorAction Stop).UsageLocation } catch { }

            if (-not $ulNow) {
                # One retry. If a sync blanked it moments ago, re-setting it now is usually
                # enough to get the licenses on; durability is a separate problem, handled
                # by -UsageLocationAdAttribute and region 6b.
                Write-Warning "Usage location is empty immediately before license assignment - Graph will refuse every SKU. Retrying the write once."
                Add-Result "Entra" $UserPrincipalName "UsageLocation pre-license check" "Warning" "Empty at license time despite being set earlier this run - retrying"
                try {
                    Update-MgUser -UserId $mgUser.Id -UsageLocation $UsageLocation -ErrorAction Stop
                    Start-Sleep -Seconds 3
                    $ulNow = (Get-MgUser -UserId $mgUser.Id -Property Id, UsageLocation -ErrorAction Stop).UsageLocation
                }
                catch {
                    Add-Result "Entra" $UserPrincipalName "UsageLocation retry" "Failed" $_.Exception.Message
                }
            }

            if (-not $ulNow) {
                # Don't fire N doomed calls. Record one clear reason per SKU instead.
                foreach ($lic in $licensesFromProfile) {
                    Add-Result "Entra-Licenses" $lic.SkuPartNumber "Set-MgUserLicense (add)" "Failed" (
                        "Not attempted: usage location is empty and Graph refuses license assignment without one. " +
                        "Set it and re-run with -CloudOnly -SamAccountName $SamAccountName. If it keeps emptying itself, " +
                        "see the Entra Connect sync-rule check below and pass -UsageLocationAdAttribute.")
                }
                Write-Warning "Skipped all $($licensesFromProfile.Count) license SKU(s): no usage location. See the report and the sync-rule check below."
            }
            else {
                Add-Result "Entra" $UserPrincipalName "UsageLocation pre-license check" "Success" "'$ulNow' present - licenses can be assigned"
            }
        }

        if ($licensesFromProfile.Count -gt 0 -and $ulNow) {
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

#region 6a. Optional: make usage location durable on the AD side
# Only runs when -UsageLocationAdAttribute names the attribute Entra Connect reads. Writing
# it in AD means the next sync flows the right value instead of overwriting the cloud value
# with an empty one. Region 6b tells you which attribute that is for this environment.
if ($UsageLocationAdAttribute -and $UsageLocation -and $UsageLocation -notlike "*CHANGE-ME*" -and $newAdUser) {
    if ($PSCmdlet.ShouldProcess($SamAccountName, "Set AD attribute $UsageLocationAdAttribute = $UsageLocation")) {
        try {
            Set-ADUser -Identity $newAdUser.DistinguishedName -Replace @{ $UsageLocationAdAttribute = $UsageLocation } -ErrorAction Stop
            Add-Result "AD" $SamAccountName "Set-ADUser $UsageLocationAdAttribute" "Success" (
                "$UsageLocation - the next sync will now flow this instead of blanking the cloud value")
            Write-Host "  AD attribute $UsageLocationAdAttribute set to $UsageLocation - usage location will survive sync." -ForegroundColor Green
        }
        catch {
            Add-Result "AD" $SamAccountName "Set-ADUser $UsageLocationAdAttribute" "Failed" (
                "$($_.Exception.Message) - check the attribute exists in the schema and accepts a string. " +
                "The cloud-side usage location is still set; only its durability across syncs is affected.")
            Write-Warning "Couldn't set AD attribute '$UsageLocationAdAttribute': $($_.Exception.Message)"
        }
    }
}
else {
    Add-Result "AD" $SamAccountName "AD-side usage location" "Skipped" (
        "-UsageLocationAdAttribute not supplied, which is correct for this tenant: no sync rule sources usageLocation " +
        "from the on-premises connector, so the cloud value is authoritative. The sync-rule check below re-confirms this each run.")
}
#endregion

#region 6b. Does Entra Connect claim usageLocation?
# This check does NOT run over remoting, and that is not a configuration problem to solve.
#
# Get-ADSyncRule and Get-ADSyncConnector talk to the sync service over a WCF named-pipe
# endpoint at net.pipe://localhost/ADSyncManagement, and named-pipe WCF endpoints are not
# reachable through PowerShell remoting. Via Invoke-Command they fail with "There was no
# endpoint listening at net.pipe://localhost/ADSyncManagement", which reads like the service
# is stopped. It isn't: the scheduler cmdlets (Start-ADSyncSyncCycle, Get-ADSyncScheduler)
# use a different channel and work remotely, so the delta sync above succeeds on the very
# same connection. That contrast makes it look like a rights problem when it's a transport one.
#
# Confirmed on ENTRACONNECT-01, 6 Aug 2026. So rather than firing a call that cannot succeed on
# every single onboarding, the check ships as Test-UsageLocationSyncRules.ps1, to be run
# locally on the sync server. -CheckUsageLocationSyncRules forces an attempt anyway, for an
# environment where remoting into that endpoint does work.
if ($UsageLocation -and $UsageLocation -notlike "*CHANGE-ME*" -and -not $WhatIfPreference) {
    if (-not $CheckUsageLocationSyncRules) {
        Add-Result "Diagnostics" "usageLocation" "Entra Connect sync-rule ownership" "Skipped" (
            "Not attempted: the ADSync management cmdlets use a named-pipe endpoint that PowerShell remoting " +
            "cannot reach, so this can only run locally on the sync server. Run Test-UsageLocationSyncRules.ps1 " +
            "there. Known good for this tenant as of 6 Aug 2026: only 'In from AAD - User Join' and " +
            "'Out to AAD - User Join' touch usageLocation, both benign, and no rule sources it from the " +
            "on-premises connector - so the cloud value is authoritative.")
    }
    else {
        Write-Host "`n--- Does Entra Connect claim usageLocation? ---" -ForegroundColor Cyan
        Write-Host "  (-CheckUsageLocationSyncRules given - attempting over remoting, which usually fails)" -ForegroundColor DarkGray
        try {
            $ulProbe = Invoke-Command -ComputerName $EntraConnectServer -ScriptBlock {
                $out = [ordered]@{ Rules = @(); Error = $null }
                try { Import-Module ADSync -ErrorAction Stop }
                catch { $out.Error = "Import-Module ADSync failed: $($_.Exception.Message)"; return [PSCustomObject]$out }
                try {
                    $found = New-Object System.Collections.Generic.List[Object]
                    foreach ($rule in (Get-ADSyncRule -ErrorAction Stop)) {
                        foreach ($m in @($rule.AttributeFlowMappings)) {
                            if ($m.Destination -eq 'usageLocation') {
                                $found.Add([PSCustomObject]@{
                                    Rule = $rule.Name; Direction = [string]$rule.Direction
                                    Disabled = [bool]$rule.Disabled; Source = (@($m.Source) -join ', ')
                                    Expression = [string]$m.Expression
                                })
                            }
                        }
                    }
                    $out.Rules = @($found)
                }
                catch { $out.Error = $_.Exception.Message }
                return [PSCustomObject]$out
            } -ErrorAction Stop

            if ($ulProbe.Error) {
                $isPipe = $ulProbe.Error -match 'net\.pipe://localhost/ADSyncManagement'
                Write-Host "  Failed: $($ulProbe.Error)" -ForegroundColor DarkYellow
                if ($isPipe) {
                    Write-Host "  This is the expected named-pipe limitation, not a fault. Run" -ForegroundColor DarkYellow
                    Write-Host "  Test-UsageLocationSyncRules.ps1 locally on $EntraConnectServer instead." -ForegroundColor DarkYellow
                }
                Add-Result "Diagnostics" "usageLocation" "Entra Connect sync-rule ownership" "Skipped" (
                    "$($ulProbe.Error)$(if ($isPipe) { ' - expected: named-pipe endpoints are unreachable over remoting. Run Test-UsageLocationSyncRules.ps1 locally on the sync server.' })")
            }
            else {
                $ulActive = @($ulProbe.Rules | Where-Object { -not $_.Disabled })
                if ($ulActive.Count -eq 0) {
                    Write-Host "  No enabled rule touches usageLocation - the cloud value is authoritative." -ForegroundColor Green
                    Add-Result "Diagnostics" "usageLocation" "Entra Connect sync-rule ownership" "Success" "No enabled rule touches usageLocation."
                }
                else {
                    foreach ($o in $ulActive) {
                        $looksAad = $o.Rule -match 'AAD|Entra'
                        $guarded  = $o.Expression -match 'IgnoreThisFlow|IsNullOrEmpty'
                        $risk = -not (($o.Direction -eq 'Inbound' -and $looksAad) -or $guarded)
                        Write-Host ("  [{0}] {1} [{2}]" -f $(if ($risk) { 'RISK  ' } else { 'BENIGN' }), $o.Rule, $o.Direction) `
                            -ForegroundColor $(if ($risk) { 'Yellow' } else { 'DarkGray' })
                        Add-Result "Diagnostics" "usageLocation" "Sync rule: $($o.Rule)" $(if ($risk) { "Warning" } else { "Info" }) (
                            "$(if ($risk) { 'RISK' } else { 'BENIGN' }) - $($o.Direction), source '$($o.Source)'. Full analysis: run Test-UsageLocationSyncRules.ps1 on the sync server.")
                    }
                }
            }
        }
        catch {
            Add-Result "Diagnostics" "usageLocation" "Entra Connect sync-rule ownership" "Skipped" $_.Exception.Message
        }
    }
}
#endregion

#region 7. Report
# Group and license work takes a while, so this reading is a good deal later than the one
# taken right after the write. If something is stripping the value, this is the cheapest
# chance to catch it inside the same run.
if ($mgUser -and $UsageLocation -and $UsageLocation -notlike "*CHANGE-ME*") {
    try {
        $ulFinal = (Get-MgUser -UserId $mgUser.Id -Property Id, UsageLocation -ErrorAction Stop).UsageLocation
        if ($ulFinal -eq $UsageLocation) {
            Add-Result "Entra" $UserPrincipalName "UsageLocation (end-of-run re-check)" "Success" "Still '$ulFinal'"
        }
        else {
            Add-Result "Entra" $UserPrincipalName "UsageLocation (end-of-run re-check)" "Warning" "Was set to '$UsageLocation' earlier in this run but now reads '$ulFinal'. Something reverted it - see the sync-rule check above."
            Write-Warning "Usage location was '$UsageLocation' earlier in this run and now reads '$ulFinal'."
        }
    }
    catch {
        Add-Result "Entra" $UserPrincipalName "UsageLocation (end-of-run re-check)" "Skipped" $_.Exception.Message
    }
}
if (-not (Test-Path $ReportPath)) {
    New-Item -Path $ReportPath -ItemType Directory -Force | Out-Null
}
$reportFile = Join-Path $ReportPath "$SamAccountName`_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $reportFile -NoTypeInformation

Write-Host "`n=== Summary for $SamAccountName ===" -ForegroundColor Cyan
$results | Format-Table Stage, Item, Action, Status -AutoSize

# A preview needs its own closing message. Reporting "All steps completed cleanly" when every
# step was skipped, and naming a report file that Export-Csv only pretended to write, both
# read as success and are worse than saying nothing.
if ($WhatIfPreference) {
    Write-Host "PREVIEW ONLY - nothing was created or changed, and no report was written." -ForegroundColor Cyan
    Write-Host "Every 'Skipped' above is expected: with no account created there is nothing" -ForegroundColor Cyan
    Write-Host "downstream to act on. Re-run without -WhatIf to do it for real." -ForegroundColor Cyan
}
else {
    $failures = $results | Where-Object { $_.Status -in @('Failed', 'Warning', 'TimedOut') }
    if ($failures) {
        Write-Warning "$($failures.Count) item(s) need manual review - see $reportFile"
    }
    else {
        Write-Host "All steps completed cleanly. Report: $reportFile" -ForegroundColor Green
    }
}

# Only ever print a password that belongs to an account that exists. Under -WhatIf the
# generator still runs (it happens while building the New-ADUser parameters), but printing
# the result would hand the operator a credential for an account that was never created -
# something they could plausibly pass on to a new hire.
if ($passwordWasGenerated -and -not $WhatIfPreference) {
    Write-Host "`n=====================================================================" -ForegroundColor Yellow
    Write-Host " TEMPORARY PASSWORD (shown once, not saved anywhere by this script):" -ForegroundColor Yellow
    Write-Host " $plainPassword" -ForegroundColor Yellow
    Write-Host " Copy this now. The account requires a password change at next logon." -ForegroundColor Yellow
    Write-Host "=====================================================================" -ForegroundColor Yellow
}
elseif ($passwordWasGenerated -and $WhatIfPreference) {
    Write-Host "`n(A temporary password was generated but is NOT shown: no account exists to own it.)" -ForegroundColor DarkGray
}
#endregion

