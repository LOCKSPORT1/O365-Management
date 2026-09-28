#Requires -Version 5.1
<#
.SYNOPSIS
    Helpdesk account recovery: reports a user's sign-in state, unlocks a locked-out AD
    account, and resets the AD password. Contoso preset.

.DESCRIPTION
    THIS IS THE VENDOR-NEUTRAL VARIANT. Environment defaults are read from environment.psd1 beside this script - copy environment.example.psd1 and fill it in before first use. Every value there is a default; the equivalent parameter always wins.

    The two things a helpdesk call actually needs - "I'm locked out" and "I forgot my
    password" - are the same call often enough that this handles both, and always shows the
    account's state first so you can see which it really was.

    Default run (no mode switch): report state, unlock if locked, reset the password, and
    require a change at next logon.

    Modes:
      -StatusOnly   Report only. Changes nothing. Safe to run against anyone, any time.
      -UnlockOnly   Report, then unlock if locked. Does NOT touch the password.
      (default)     Report, unlock if locked, and reset the password.

    What gets reported before anything is changed:
      - Enabled / disabled, and the OU the object sits in
      - LockedOut, AccountLockoutTime
      - PasswordLastSet, password age, PasswordExpired, PasswordNeverExpires
      - Computed password expiry date
      - BadLogonCount and LastBadPasswordAttempt, queried from EVERY domain controller
        rather than just the one you happen to bind to - see LOCKOUT SOURCE below.

.NOTES
    SAFETY - THE OFFBOARDED-ACCOUNT GUARD
      Offboard-HybridUser.ps1 disables the account and moves it to the
      shared-mailbox OU. An account in that state is a former employee, and resetting its
      password or unlocking it hands working credentials back to someone who has left. Two
      guards, both requiring -Force to override:

        1. The account is disabled.
        2. The account's DN is inside the shared-mailbox / disabled-users OU.

      Either one stops the run before any change is made. -StatusOnly is never blocked,
      because looking is always safe. This script never enables a disabled account, even
      with -Force - if an account genuinely needs re-enabling, that is a deliberate act and
      belongs in Enable-ADAccount by hand, not as a side effect of a password reset.

    SECURITY NOTE ON THE PASSWORD
      Like New-UserFromAccessProfile, this script deliberately does NOT call
      Start-Transcript. A generated password is shown once in the console and is never
      written to the CSV report or any log by this script. Copy it before closing the
      window.

    HYBRID BEHAVIOUR - READ THIS BEFORE CHASING A "SYNC PROBLEM"
      Password reset:
        With Password Hash Sync, the new hash reaches Entra ID by its own channel, typically
        within about two minutes. Start-ADSyncSyncCycle -PolicyType Delta does NOT push
        password hashes, so this script deliberately does not trigger a delta sync after a
        reset - it would achieve nothing and imply a guarantee it can't make. With
        Pass-through Authentication there is nothing to sync: the on-prem password IS the
        password. Either way, wait a couple of minutes before concluding it failed.

      Unlock:
        AD account lockout is on-premises only, and Unlock-ADAccount clears it on the DC you
        bind to; AD replication carries it to the rest. Entra ID has its own, separate smart
        lockout that CANNOT be manually cleared by any cmdlet - it expires on its own. So a
        user who is locked out in the cloud may still be refused for a few more minutes after
        a successful AD unlock. That is expected, not a failed unlock.

    LOCKOUT SOURCE
      BadLogonCount and LastBadPasswordAttempt are per-DC, not replicated attributes. Read
      from a single DC they are close to meaningless. This script queries every DC and shows
      each one's count, so a stale mapped drive or a phone with an old saved password shows
      up as a single DC with a climbing count. To find the actual machine, pull event 4740
      (and 4771/4625) from the Security log of the DC with the highest count - that stays a
      manual step, since it needs log-read rights this script does not assume.

    Run from an admin workstation with the ActiveDirectory RSAT module installed, or from a
    domain controller. -RevokeCloudSessions additionally needs Graph.

.PARAMETER SamAccountName
    The user's AD logon name, e.g. jsmith. Prompted for if omitted in an interactive session.

.PARAMETER StatusOnly
    Report the account's state and change nothing. Not blocked by the offboarded-account
    guard. Mutually exclusive with -UnlockOnly.

.PARAMETER UnlockOnly
    Report, then unlock the account if it's locked. Leaves the password alone. Mutually
    exclusive with -StatusOnly.

.PARAMETER NewPassword
    The password to set, as a SecureString. If omitted, a random 16-character complex
    password is generated and shown once in the console.

.PARAMETER NoChangeAtLogon
    Controls whether the user must set their own password at next logon.

    Omit it and an interactive run ASKS you, defaulting to Yes on an empty answer. Pass it
    explicitly - either -NoChangeAtLogon or -NoChangeAtLogon:$false - and that wins with no
    prompt, so scheduled and scripted runs stay deterministic and never block waiting for
    input. A non-interactive run with neither given requires the change.

    You are not asked at all if the account has PasswordNeverExpires or CannotChangePassword
    set, because AD won't honour a forced change alongside either; the script says so instead.

    Yes is the recommended answer: a password you have seen and read out to someone is a
    password only they should know from that point on.

.PARAMETER RevokeCloudSessions
    Also revoke the user's Entra ID refresh tokens, so existing signed-in sessions on other
    devices stop working. Use this whenever the reset is because of a suspected compromise -
    without it, a password reset does not evict an attacker who already holds a token.

.PARAMETER Force
    Override the offboarded-account guard: proceed even though the account is disabled or
    sits in the shared-mailbox OU. Does not enable a disabled account.

.PARAMETER SharedMailboxOU
    DN of the shared-mailbox / disabled-users OU used by the guard. Defaults to the section 0
    preset, which matches the offboarding script's.

.PARAMETER ReportPath
    Folder for the CSV report. Defaults to Reports\AccountResets inside this script's own
    folder, resolved via $PSScriptRoot so the package stays portable.

.PARAMETER AutoInstallMissingModules
    Install a missing PSGallery module automatically instead of prompting. Only relevant
    with -RevokeCloudSessions; the ActiveDirectory module comes from RSAT and can never be
    installed this way.

.EXAMPLE
    .\Reset-UserPassword.ps1 -SamAccountName jsmith -StatusOnly
    Is she actually locked out, or is her password just expired? Changes nothing.

.EXAMPLE
    .\Reset-UserPassword.ps1 -SamAccountName jsmith -UnlockOnly
    She knows her password, she just fat-fingered it five times.

.EXAMPLE
    .\Reset-UserPassword.ps1 -SamAccountName jsmith
    Unlock if locked, reset the password, force a change at next logon.

.EXAMPLE
    .\Reset-UserPassword.ps1 -SamAccountName jsmith -RevokeCloudSessions
    Same, plus kill existing cloud sessions. Use this one for a suspected compromise.

.EXAMPLE
    .\Reset-UserPassword.ps1 -SamAccountName jsmith -WhatIf
    Show exactly what would change. The status report still runs for real - it's read-only.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Reset')]
param(
    [Parameter(Position = 0)]
    [string]$SamAccountName,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$StatusOnly,

    [Parameter(ParameterSetName = 'Unlock')]
    [switch]$UnlockOnly,

    [Parameter(ParameterSetName = 'Reset')]
    [System.Security.SecureString]$NewPassword,

    [Parameter(ParameterSetName = 'Reset')]
    [switch]$NoChangeAtLogon,

    [switch]$RevokeCloudSessions,

    [switch]$Force,

    [string]$SharedMailboxOU,

    [string]$ReportPath,

    [switch]$AutoInstallMissingModules
)

# --- Portable path resolution ----------------------------------------------------------
# Resolve output locations against THIS SCRIPT'S OWN FOLDER so the package works unchanged
# from a UNC share, a mapped drive or a local disk. $PSScriptRoot deliberately rather than
# '.\' or $PWD, which resolve against wherever PowerShell started (C:\Windows\System32 when
# launched from a shortcut or the Run box).
$Script:PackageRoot = $PSScriptRoot
if (-not $Script:PackageRoot) { $Script:PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Script:PackageRoot) { $Script:PackageRoot = (Get-Location).Path }
if (-not $ReportPath) { $ReportPath = Join-Path $Script:PackageRoot 'Reports\AccountResets' }
# ---------------------------------------------------------------------------------------

#region 0. Configuration (the organization preset)
# ---------------------------------------------------------------------------------------
# Must match $Script:DefaultSharedMailboxOU in Offboard-HybridUser.ps1. If that
# OU ever moves, change it in both places - this is the OU the offboarded-account guard
# checks against, so a stale value here silently weakens the guard.
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

$Script:DefaultSharedMailboxOU = Get-EnvSetting -Name 'SharedMailboxOU'

# Bumped on any meaningful behaviour change. Logged as the first row of every report so a
# saved CSV alone tells you which build produced it.
$Script:ScriptVersion = "2026-08-06.4 (Graph module version preflight; Graph conflict diagnosis; status, unlock, reset, offboarded-account guard, per-DC bad-password counts)"

$Script:RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
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

Add-Result "Meta" "ScriptVersion" "Run started" "Info" $Script:ScriptVersion

function Save-Report {
    if (-not (Test-Path $ReportPath)) {
        New-Item -Path $ReportPath -ItemType Directory -Force | Out-Null
    }
    $file = Join-Path $ReportPath "$SamAccountName`_$Script:RunStamp.csv"
    $results | Export-Csv -Path $file -NoTypeInformation
    return $file
}

# Same generator as New-UserFromAccessProfile, and for the same reason: O, 0, l, 1 and I
# are all absent from the character sets, because these get read aloud over the phone.
# Verified: 0 occurrences across 500 generated samples.
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

#region 1. Modules
Ensure-Module -Name 'ActiveDirectory' -IsWindowsFeature -ManualInstallHint (
    "Windows 10/11: Settings > Optional Features > Add a feature > 'RSAT: Active Directory " +
    "Domain Services and Lightweight Directory Tools' (or run, as admin: " +
    "Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0). " +
    "Windows Server: Install-WindowsFeature RSAT-AD-PowerShell."
)
if ($RevokeCloudSessions) {
Test-GraphModuleVersions

    Ensure-Module -Name 'Microsoft.Graph.Users' -ManualInstallHint "Install-Module Microsoft.Graph.Users -Scope CurrentUser"
    Ensure-Module -Name 'Microsoft.Graph.Users.Actions' -ManualInstallHint "Install-Module Microsoft.Graph.Users.Actions -Scope CurrentUser"
}
#endregion

#region 2. Identify the user
if (-not $SamAccountName) {
    if ([Environment]::UserInteractive -and $Host.Name -ne 'Default Host') {
        Write-Host ""
        $SamAccountName = (Read-Host "  AD username (SamAccountName)").Trim()
    }
    if (-not $SamAccountName) {
        throw "-SamAccountName is required."
    }
}

$mode = if ($StatusOnly) { 'Status only' } elseif ($UnlockOnly) { 'Unlock only' } else { 'Unlock + password reset' }
Write-Host ""
Write-Host "=== Account recovery: $SamAccountName ===" -ForegroundColor Cyan
Write-Host "    Mode: $mode" -ForegroundColor DarkCyan

$adProps = @(
    'LockedOut', 'Enabled', 'DistinguishedName', 'UserPrincipalName', 'DisplayName',
    'PasswordLastSet', 'PasswordExpired', 'PasswordNeverExpires', 'CannotChangePassword',
    'BadLogonCount', 'LastBadPasswordAttempt', 'AccountLockoutTime', 'whenCreated',
    'msDS-UserPasswordExpiryTimeComputed', 'Department', 'Title'
)
$user = Get-ADUser -Identity $SamAccountName -Properties $adProps -ErrorAction SilentlyContinue
if (-not $user) {
    Add-Result "AD" $SamAccountName "Get-ADUser" "Failed" "No AD user with that SamAccountName"
    $f = Save-Report
    throw "No AD user found with SamAccountName '$SamAccountName'. Check the spelling, or search: Get-ADUser -Filter `"Name -like '*$SamAccountName*'`" | Select Name, SamAccountName. Report: $f"
}
Add-Result "AD" $SamAccountName "Get-ADUser" "Success" $user.DistinguishedName
#endregion

#region 3. Status report (always read-only, always runs - including under -WhatIf)
Write-Host ""
Write-Host "--- Account state ---" -ForegroundColor Cyan

$pwdLastSet = $user.PasswordLastSet
$pwdAgeDays = if ($pwdLastSet) { [int]((Get-Date) - $pwdLastSet).TotalDays } else { $null }

$pwdExpiry = $null
$rawExpiry = $user.'msDS-UserPasswordExpiryTimeComputed'
# 0 = must change at next logon; 9223372036854775807 = never expires. Neither is a date.
if ($rawExpiry -and $rawExpiry -ne 0 -and $rawExpiry -ne 9223372036854775807) {
    try { $pwdExpiry = [datetime]::FromFileTime($rawExpiry) } catch { $pwdExpiry = $null }
}

# A DN's CN can legitimately contain an escaped comma ("CN=Smith\, John,OU=..."), so a
# plain -split ',' lops the DN in the wrong place and reports the wrong OU. Split only on
# commas that are NOT backslash-escaped.
function Get-ParentOU {
    param([string]$DistinguishedName)
    $parts = $DistinguishedName -split '(?<!\\),', 2
    if ($parts.Count -ge 2) { return $parts[1] }
    return $DistinguishedName
}

function Write-Field {
    param($Label, $Value, $Colour = 'Gray')
    Write-Host ("  {0,-26} {1}" -f "$Label :", $Value) -ForegroundColor $Colour
}

Write-Field 'Display name'   $user.DisplayName
Write-Field 'UPN'            $user.UserPrincipalName
Write-Field 'Department'     $(if ($user.Department) { $user.Department } else { '(none)' })
Write-Field 'OU'             (Get-ParentOU $user.DistinguishedName)
Write-Field 'Enabled'        $user.Enabled                    $(if ($user.Enabled) { 'Green' } else { 'Red' })
Write-Field 'Locked out'     $user.LockedOut                  $(if ($user.LockedOut) { 'Yellow' } else { 'Green' })
if ($user.AccountLockoutTime) { Write-Field 'Lockout time' $user.AccountLockoutTime 'Yellow' }
Write-Field 'Password last set' $(if ($pwdLastSet) { "$pwdLastSet  ($pwdAgeDays days ago)" } else { 'never' })
Write-Field 'Password expired' $user.PasswordExpired          $(if ($user.PasswordExpired) { 'Yellow' } else { 'Green' })
Write-Field 'Never expires'   $user.PasswordNeverExpires      $(if ($user.PasswordNeverExpires) { 'Yellow' } else { 'Gray' })
Write-Field 'Cannot change'   $user.CannotChangePassword      $(if ($user.CannotChangePassword) { 'Yellow' } else { 'Gray' })
if ($pwdExpiry) { Write-Field 'Password expires' $pwdExpiry }
Write-Field 'Last bad password' $(if ($user.LastBadPasswordAttempt) { $user.LastBadPasswordAttempt } else { 'none recorded' })

Add-Result "Status" $SamAccountName "Enabled" "Info" $user.Enabled
Add-Result "Status" $SamAccountName "LockedOut" "Info" $user.LockedOut
Add-Result "Status" $SamAccountName "AccountLockoutTime" "Info" $user.AccountLockoutTime
Add-Result "Status" $SamAccountName "PasswordLastSet" "Info" "$pwdLastSet ($pwdAgeDays days)"
Add-Result "Status" $SamAccountName "PasswordExpired" "Info" $user.PasswordExpired
Add-Result "Status" $SamAccountName "PasswordNeverExpires" "Info" $user.PasswordNeverExpires
Add-Result "Status" $SamAccountName "PasswordExpiryComputed" "Info" $pwdExpiry
Add-Result "Status" $SamAccountName "OU" "Info" (Get-ParentOU $user.DistinguishedName)

# Per-DC bad-password counts. These attributes don't replicate, so the DC you happen to
# bind to tells you almost nothing on its own.
Write-Host ""
Write-Host "--- Bad-password attempts per DC (not a replicated attribute) ---" -ForegroundColor Cyan
try {
    $dcs = @(Get-ADDomainController -Filter * -ErrorAction Stop)
    foreach ($dc in ($dcs | Sort-Object HostName)) {
        try {
            $perDc = Get-ADUser -Identity $SamAccountName -Server $dc.HostName `
                     -Properties BadLogonCount, LastBadPasswordAttempt, LockedOut, AccountLockoutTime -ErrorAction Stop
            $colour = if ($perDc.BadLogonCount -gt 0) { 'Yellow' } else { 'Gray' }
            Write-Host ("  {0,-32} bad: {1,-4} last: {2}  locked: {3}" -f `
                $dc.HostName, $perDc.BadLogonCount,
                $(if ($perDc.LastBadPasswordAttempt) { $perDc.LastBadPasswordAttempt } else { '-' }),
                $perDc.LockedOut) -ForegroundColor $colour
            Add-Result "Status-PerDC" $dc.HostName "BadLogonCount" "Info" `
                "count: $($perDc.BadLogonCount) | last bad: $($perDc.LastBadPasswordAttempt) | locked: $($perDc.LockedOut)"
        }
        catch {
            Write-Host ("  {0,-32} unreachable" -f $dc.HostName) -ForegroundColor DarkYellow
            Add-Result "Status-PerDC" $dc.HostName "BadLogonCount" "Failed" $_.Exception.Message
        }
    }
    $worst = $null
    foreach ($dc in $dcs) {
        try {
            $p = Get-ADUser -Identity $SamAccountName -Server $dc.HostName -Properties BadLogonCount -ErrorAction Stop
            if ($p.BadLogonCount -gt 0 -and (-not $worst -or $p.BadLogonCount -gt $worst.Count)) {
                $worst = [PSCustomObject]@{ Host = $dc.HostName; Count = $p.BadLogonCount }
            }
        } catch { }
    }
    if ($worst) {
        Write-Host ""
        Write-Host "  Most bad attempts: $($worst.Host) ($($worst.Count))." -ForegroundColor Yellow
        Write-Host "  To find the source machine, check event 4740 / 4771 / 4625 in that DC's Security log." -ForegroundColor Yellow
        Add-Result "Status" $worst.Host "Highest bad-password count" "Warning" "$($worst.Count) - check events 4740/4771/4625 on this DC for the source machine"
    }
}
catch {
    Add-Result "Status-PerDC" "n/a" "Get-ADDomainController" "Failed" $_.Exception.Message
    Write-Warning "Couldn't enumerate domain controllers: $($_.Exception.Message). Per-DC counts skipped; the single-DC figures above still apply."
}
#endregion

#region 4. Offboarded-account guard
# Runs before any change. -StatusOnly never reaches here, because looking is always safe.
if (-not $StatusOnly) {
    $guardHits = New-Object System.Collections.Generic.List[string]
    if (-not $user.Enabled) {
        $guardHits.Add("the account is DISABLED")
    }
    if ($user.DistinguishedName -like "*$SharedMailboxOU") {
        $guardHits.Add("the account sits in the shared-mailbox / disabled-users OU ($SharedMailboxOU)")
    }

    if ($guardHits.Count -gt 0) {
        $why = $guardHits -join ", and "
        Write-Host ""
        Write-Host "  ================================================================" -ForegroundColor Red
        Write-Host "   STOPPED: $why." -ForegroundColor Red
        Write-Host "   That is what Offboard-HybridUser does to a departed employee." -ForegroundColor Red
        Write-Host "   Unlocking or resetting would hand back working credentials." -ForegroundColor Red
        Write-Host "  ================================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "   If this really is a current employee - a mistaken offboarding, or" -ForegroundColor Yellow
        Write-Host "   a returning one - re-enable and move the account deliberately," -ForegroundColor Yellow
        Write-Host "   then re-run. To override this check, pass -Force." -ForegroundColor Yellow
        Write-Host ""

        Add-Result "Guard" $SamAccountName "Offboarded-account guard" $(if ($Force) { "Warning" } else { "Blocked" }) $why

        if (-not $Force) {
            $f = Save-Report
            Write-Host "Nothing was changed. Report: $f" -ForegroundColor Yellow
            return
        }
        Write-Warning "-Force specified - continuing anyway. This account will NOT be enabled by this script."
    }
    else {
        Add-Result "Guard" $SamAccountName "Offboarded-account guard" "Success" "Account is enabled and outside the shared-mailbox OU"
    }
}
#endregion

#region 5. Unlock
if ($StatusOnly) {
    Add-Result "Unlock" $SamAccountName "Unlock-ADAccount" "Skipped" "-StatusOnly specified"
}
elseif (-not $user.LockedOut) {
    Write-Host ""
    Write-Host "  Not locked out - nothing to unlock." -ForegroundColor Green
    Add-Result "Unlock" $SamAccountName "Unlock-ADAccount" "Skipped" "Account was not locked out"
}
elseif ($PSCmdlet.ShouldProcess($SamAccountName, "Unlock-ADAccount")) {
    try {
        Unlock-ADAccount -Identity $user.DistinguishedName -ErrorAction Stop
        Write-Host ""
        Write-Host "  Unlocked." -ForegroundColor Green
        Add-Result "Unlock" $SamAccountName "Unlock-ADAccount" "Success" "Cleared on the bound DC; AD replication carries it to the others"
        Write-Host "  Note: Entra ID smart lockout is separate and can't be cleared manually -" -ForegroundColor DarkYellow
        Write-Host "        cloud sign-in may still be refused for a few more minutes." -ForegroundColor DarkYellow
        Add-Result "Unlock" $SamAccountName "Entra smart lockout" "Info" "Separate from AD lockout, cannot be cleared by cmdlet, expires on its own"
    }
    catch {
        Add-Result "Unlock" $SamAccountName "Unlock-ADAccount" "Failed" $_.Exception.Message
        Write-Warning "Unlock failed: $($_.Exception.Message)"
    }
}
#endregion

#region 6. Password reset
$plainPassword = $null
if ($StatusOnly -or $UnlockOnly) {
    Add-Result "Password" $SamAccountName "Set-ADAccountPassword" "Skipped" "$mode - password untouched"
}
else {
    # ---- Decide the change-at-next-logon behaviour BEFORE anything is written -------
    # An explicitly passed -NoChangeAtLogon (or -NoChangeAtLogon:$false) always wins and is
    # never second-guessed, so scheduled and scripted runs stay deterministic and never
    # block on a prompt. We only ask when the caller said nothing at all, and only when
    # there's a human present to answer.
    $requireChangeAtLogon = -not $NoChangeAtLogon
    $changeDecisionSource = if ($PSBoundParameters.ContainsKey('NoChangeAtLogon')) {
        "explicit -NoChangeAtLogon:`$$([bool]$NoChangeAtLogon)"
    } else { 'default (require change)' }

    if (-not $PSBoundParameters.ContainsKey('NoChangeAtLogon')) {
        if ($user.PasswordNeverExpires -or $user.CannotChangePassword) {
            # AD will not honour a forced change on this account, so don't ask a question
            # whose answer we'd have to ignore. Reported below either way.
            $requireChangeAtLogon = $false
            $flag = if ($user.PasswordNeverExpires) { 'PasswordNeverExpires' } else { 'CannotChangePassword' }
            $changeDecisionSource = "not offered - $flag is set on this account"
            Write-Host ""
            Write-Host "  Not asking about a forced password change: $flag is set on this" -ForegroundColor DarkYellow
            Write-Host "  account, and AD won't allow 'must change at next logon' alongside it." -ForegroundColor DarkYellow
        }
        elseif ($WhatIfPreference) {
            $changeDecisionSource = 'default (not prompted under -WhatIf)'
        }
        elseif ([Environment]::UserInteractive -and $Host.Name -ne 'Default Host') {
            Write-Host ""
            Write-Host "  Require a password change at next logon?" -ForegroundColor Cyan
            Write-Host "    Y  they set their own password when they next sign in (recommended)" -ForegroundColor DarkGray
            Write-Host "    N  the password you hand over stays as their password" -ForegroundColor DarkGray
            Write-Host ""
            $ans = Read-Host "  [Y/n]"
            if ($ans -and $ans.Trim() -match '^(n|no)$') {
                $requireChangeAtLogon = $false
                $changeDecisionSource = 'answered No at prompt'
                Write-Host "  Will NOT force a change - the password you hand over is permanent." -ForegroundColor Yellow
            }
            else {
                $requireChangeAtLogon = $true
                $changeDecisionSource = 'answered Yes at prompt'
                Write-Host "  Will force a change at next logon." -ForegroundColor Green
            }
        }
    }
    Add-Result "Password" $SamAccountName "Change-at-logon decision" "Info" (
        "$(if ($requireChangeAtLogon) { 'Require change' } else { 'Do not require change' }) - $changeDecisionSource")
    # -------------------------------------------------------------------------------

    $generated = $false
    if (-not $NewPassword) {
        $plainPassword = New-RandomPassword
        $NewPassword   = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
        $generated     = $true
    }

    if ($PSCmdlet.ShouldProcess($SamAccountName, "Set-ADAccountPassword (reset)")) {
        try {
            Set-ADAccountPassword -Identity $user.DistinguishedName -Reset -NewPassword $NewPassword -ErrorAction Stop
            Add-Result "Password" $SamAccountName "Set-ADAccountPassword" "Success" $(if ($generated) { "Generated, shown once in console, not logged" } else { "Supplied via -NewPassword" })
            Write-Host ""
            Write-Host "  Password reset." -ForegroundColor Green
        }
        catch {
            Add-Result "Password" $SamAccountName "Set-ADAccountPassword" "Failed" $_.Exception.Message
            $f = Save-Report
            throw "Password reset failed for '$SamAccountName': $($_.Exception.Message). If this is a complexity or minimum-age policy rejection, check the domain password policy (Get-ADDefaultDomainPasswordPolicy) and any fine-grained policy on this user. Report: $f"
        }

        # Apply the decision made above. The two flag checks below are still needed as a
        # backstop: when -NoChangeAtLogon was passed explicitly we skipped the pre-check,
        # and PasswordNeverExpires / ChangePasswordAtLogon are mutually exclusive in AD, so
        # say so plainly rather than letting Set-ADUser throw something cryptic.
        if (-not $requireChangeAtLogon) {
            Add-Result "Password" $SamAccountName "ChangePasswordAtLogon" "Skipped" $changeDecisionSource
        }
        elseif ($user.PasswordNeverExpires) {
            Write-Warning "PasswordNeverExpires is set on this account, which AD won't allow alongside 'must change at next logon'. Left as-is - the password you just set is permanent until changed."
            Add-Result "Password" $SamAccountName "ChangePasswordAtLogon" "Skipped" "Incompatible with PasswordNeverExpires, which is set on this account. Clear that flag first if a forced change is wanted."
        }
        elseif ($user.CannotChangePassword) {
            Write-Warning "CannotChangePassword is set on this account, so the user can't perform the forced change. Left as-is."
            Add-Result "Password" $SamAccountName "ChangePasswordAtLogon" "Skipped" "CannotChangePassword is set on this account"
        }
        else {
            try {
                Set-ADUser -Identity $user.DistinguishedName -ChangePasswordAtLogon $true -ErrorAction Stop
                Add-Result "Password" $SamAccountName "ChangePasswordAtLogon" "Success" "User must change at next logon"
            }
            catch {
                Add-Result "Password" $SamAccountName "ChangePasswordAtLogon" "Failed" $_.Exception.Message
                Write-Warning "Couldn't set 'must change at next logon': $($_.Exception.Message). The new password is active regardless."
            }
        }
    }
}
#endregion

#region 7. Optional: revoke Entra sessions
if (-not $RevokeCloudSessions) {
    Add-Result "Entra" $SamAccountName "Revoke-MgUserSignInSession" "Skipped" "-RevokeCloudSessions not specified. A password reset alone does not evict a session that already holds a refresh token."
}
elseif ($PSCmdlet.ShouldProcess($user.UserPrincipalName, "Revoke Entra ID sign-in sessions")) {
    try {
        if (-not (Get-MgContext)) {
            Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.Read.All" -NoWelcome
        }
        $mgUser = Get-MgUser -UserId $user.UserPrincipalName -Property Id, UserPrincipalName -ErrorAction Stop
        Revoke-MgUserSignInSession -UserId $mgUser.Id -ErrorAction Stop | Out-Null
        Write-Host "  Entra sign-in sessions revoked." -ForegroundColor Green
        Add-Result "Entra" $user.UserPrincipalName "Revoke-MgUserSignInSession" "Success" "Refresh tokens invalidated; existing sessions will re-prompt"
    }
    catch {
        Add-Result "Entra" $user.UserPrincipalName "Revoke-MgUserSignInSession" "Failed" $_.Exception.Message
        Write-Warning "Couldn't revoke cloud sessions: $($_.Exception.Message)"
    }
}
#endregion

#region 8. Report + hand-off
$reportFile = Save-Report

Write-Host ""
Write-Host "=== Summary for $SamAccountName ===" -ForegroundColor Cyan
$results | Where-Object { $_.Stage -ne 'Status-PerDC' -and $_.Status -ne 'Info' } |
    Format-Table Stage, Action, Status -AutoSize

# Printed last, on purpose: it stays on screen under everything else, and it is the one
# thing here that is never written to disk.
if ($plainPassword) {
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Green
    Write-Host "   Temporary password for $($user.UserPrincipalName)" -ForegroundColor Green
    Write-Host ""
    Write-Host "        $plainPassword" -ForegroundColor White
    Write-Host ""
    Write-Host "   Shown once. Not written to the report or any log." -ForegroundColor Green
    if ($requireChangeAtLogon) {
        Write-Host "   They must change it at next logon." -ForegroundColor Green
    }
    else {
        Write-Host "   This is now their permanent password - no change is forced." -ForegroundColor Yellow
    }
    Write-Host "   Hand it over out-of-band - not by email to the account you just reset." -ForegroundColor Green
    Write-Host "  ----------------------------------------------------------------" -ForegroundColor Green
    Write-Host ""
    Write-Host "   Hybrid: with Password Hash Sync the new password reaches Entra in" -ForegroundColor DarkCyan
    Write-Host "   roughly two minutes by its own channel - a delta sync won't speed" -ForegroundColor DarkCyan
    Write-Host "   that up, so give it a moment before assuming it didn't work." -ForegroundColor DarkCyan
    Write-Host ""
}

$failures = $results | Where-Object { $_.Status -in @('Failed', 'Warning', 'Blocked') }
if ($failures) {
    Write-Warning "$($failures.Count) item(s) need review - see $reportFile"
}
else {
    Write-Host "Done. Report: $reportFile" -ForegroundColor Green
}
#endregion

