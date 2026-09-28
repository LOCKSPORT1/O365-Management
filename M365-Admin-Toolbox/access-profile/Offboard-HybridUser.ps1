#Requires -Version 5.1
<#
.SYNOPSIS
    Offboards a user in a hybrid Entra ID / on-prem Active Directory environment:
    disables the AD account, converts the mailbox to shared, removes all assigned Entra ID
    licenses, relocates the AD object to the shared-mailbox OU, strips the user from every
    AD group and every cloud (Entra ID) group they can be removed from, and revokes active
    cloud sessions.

.DESCRIPTION
    THIS IS THE VENDOR-NEUTRAL VARIANT. Environment defaults are read from environment.psd1 beside this script - copy environment.example.psd1 and fill it in before first use. Every value there is a default; the equivalent parameter always wins.

    

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
      3. Convert the user's mailbox to a shared mailbox (Exchange Online), then grant the
         manager Full Access to it (-ManagerUpn, or the AD Manager attribute if not passed)
         so the preserved mail is actually reachable.
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
    Defaults to the configured shared mailbox OU (see section "0. Configuration").
    Pass this explicitly only if a user needs to land somewhere else.

.PARAMETER SkipMailboxConversion
    Skip the Exchange Online shared-mailbox conversion step (e.g. user had no mailbox).

.PARAMETER ManagerUpn
    UPN of the person who should get Full Access to the converted shared mailbox. If omitted,
    the script reads the departing user's AD Manager attribute and uses that. If neither is
    available the conversion still happens but is reported as a Warning, because a shared
    mailbox nobody can open is the most common post-offboarding complaint.

.PARAMETER AutoMapSharedMailbox
    Force-mount the shared mailbox in the manager's Outlook profile (Add-MailboxPermission
    -AutoMapping $true). Off by default - automapping a departed employee's mailbox into
    someone's Outlook is usually unwanted, and it can't be undone without removing and
    re-adding the permission.

.PARAMETER SkipLicenseRemoval
    Opt-out switch. By default the script removes every Entra ID license currently
    assigned to the user (via Set-MgUserLicense) right after the mailbox conversion step.
    Pass this switch to leave licenses assigned (e.g. a temporary leave rather than a
    permanent offboarding).

.PARAMETER SkipDeviceStage
    Skip the device stage entirely (no Intune/Entra device lookup, no notes written). Use
    this if you handle devices in a separate process, or to get the pre-device behaviour of
    this script back exactly.

.PARAMETER RetireIntuneDevices
    Additionally retire every Intune device found for this user. Retire removes company
    data and unenrolls the device; it does not wipe personal data and does not delete the
    Intune record. OFF BY DEFAULT ON PURPOSE - see .NOTES on primary-user accuracy. Without
    this switch the device stage only reports and flags.

.PARAMETER SkipDeviceNote
    Report the user's devices but don't write the offboarding note into the Intune device
    Notes field. The stage becomes entirely read-only.

.PARAMETER SkipEntraSyncWait
    Skip triggering/waiting on an Entra Connect delta sync before evaluating cloud groups.
    Only use this if you already know a sync has run recently, otherwise synced-group
    memberships may look "stuck" in step 6 simply because AD's removal hasn't replicated up yet.

.PARAMETER EntraConnectServer
    Hostname of the Entra Connect / AD Connect server, used to remotely trigger
    Start-ADSyncSyncCycle over PowerShell remoting. Defaults to the configured Entra Connect
    server (see $Script:DefaultEntraConnectServer in section "0. Configuration"), so you
    normally don't pass this. Requires PowerShell remoting rights to that server; if you
    don't have them the sync trigger is reported as Failed and every AD-synced group will be
    flagged "Verify sync-removed" simply because Entra hasn't caught up - see .PARAMETER
    SkipSyncRecheck.

.PARAMETER SyncWaitTimeoutSeconds
    How long to wait for the triggered Entra Connect delta sync cycle to finish before giving
    up and proceeding anyway (reported as TimedOut). Defaults to 300 seconds, polled every 15.

.PARAMETER SkipSyncRecheck
    Skip the second-pass re-check of synced groups that still showed the user as a member
    when first evaluated. Off by default - the script waits -SyncRecheckWaitSeconds and
    re-checks so the report shows whether they actually cleared.

.PARAMETER SyncRecheckWaitSeconds
    How long to wait before the second-pass re-check in .PARAMETER SkipSyncRecheck above.
    Defaults to 90 seconds. Increase this if your environment's Entra Connect -> Entra ID
    replication typically takes longer to catch up.

.PARAMETER ReportPath
    Folder to write the per-run CSV report and transcript log to. Defaults to a Reports\
    subfolder inside this script's own package folder, resolved via $PSScriptRoot - so the
    package is self-contained and works unchanged from a flash drive, a share, or a local
    disk. Deliberately not a relative ".\..." path, which resolves against whatever directory
    PowerShell happened to start in (e.g. C:\Windows\System32 when launched from a shortcut
    or the Run box).

    Offboarding is an HR/legal event and the report is the evidence, so if several admins run
    this from separate copies of the package, point them all at one shared location:

        -ReportPath '\\ENTRACONNECT-01\installs$\Scripts\OffboardingReports'

    If the target can't be written to - read-only share, write-protected flash drive, full
    disk - the script falls back to %LOCALAPPDATA%\OffboardingReports, logs a Warning row and
    prints a notice. It will not abort an in-progress offboarding over a reporting problem.

.PARAMETER AutoInstallMissingModules
    If a required PSGallery module (ExchangeOnlineManagement, Microsoft.Graph.*) isn't installed,
    install it automatically for the current user instead of prompting. The ActiveDirectory
    module (RSAT) can never be auto-installed this way - see .NOTES.

.PARAMETER WhatIf
    Standard ShouldProcess support - preview every change without making it.

.EXAMPLE
    .\Offboard-HybridUser.ps1 -SamAccountName jsmith
    (Typical run. Shared-mailbox OU, Entra Connect server and report path all come from the
    presets in section 0, and the manager is read from AD - so this is usually all you need.)

.EXAMPLE
    .\Offboard-HybridUser.ps1 -SamAccountName jsmith -ManagerUpn dsmith@contoso.com
    (Explicit mailbox delegate - use when the AD Manager attribute is empty or wrong, e.g. the
    manager left too, or the team is being reassigned.)

.EXAMPLE
    .\Offboard-HybridUser.ps1 -SamAccountName jsmith -SkipLicenseRemoval

.EXAMPLE
    .\Offboard-HybridUser.ps1 -SamAccountName jsmith -WhatIf

.EXAMPLE
    .\Offboard-HybridUser.ps1 -SamAccountName jsmith -CloudOnly
    (AD-side steps already completed in a prior run - just retries mailbox conversion,
    license removal, cloud group cleanup, and session revoke.)

.NOTES
    Version : see $Script:ScriptVersion in section 0 below - also printed in the startup
              banner and logged as the first row of every CSV report, so a saved report
              alone tells you whether that run had license removal / sync recheck / etc.
              If a report is missing features described in this help text, you were
              running an older copy - replace it with the current file from this folder.

    Required modules  : ActiveDirectory, ExchangeOnlineManagement,
                         Microsoft.Graph.Users, Microsoft.Graph.Groups,
                         Microsoft.Graph.Identity.DirectoryManagement,
                         Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Users.Actions
                         (Microsoft.Graph.Users.Actions is only checked/installed if
                         license removal actually runs, i.e. -SkipLicenseRemoval is not set)
    Required Graph scopes (delegated or app-only) :
                         User.ReadWrite.All, Group.ReadWrite.All,
                         GroupMember.ReadWrite.All, Directory.Read.All

    ENTRA CONNECT SERVER (only needed if you want this script to trigger a sync)
      - Hostname of whichever server has Microsoft Entra Connect (formerly Azure AD
        Connect) installed. Confirm you have the right box by running, ON that server:
        Get-ADSyncScheduler
      - If you don't know it or don't want to grant remoting rights to it, omit
        -EntraConnectServer; the script still works, it just won't trigger a sync itself.

    DEVICE STAGE - WHY IT FLAGS RATHER THAN RETIRES
      Intune's Primary User is frequently wrong in this environment: it is set from the
      first user to sign in after enrolment and is not updated when a machine is handed to
      someone else. That is the whole reason Invoke-PrimaryUserAudit exists. Retiring on
      the strength of that field alone can therefore wipe company data off a machine that
      now belongs to a current employee.

      So by default this stage is near-read-only: it lists every Intune managed device and
      every Entra-registered device for the user, writes a dated offboarding note into the
      Intune Notes field of each, and records them all in the CSV for the manual checklist.
      Nothing is unenrolled, retired, wiped or deleted. Pass -RetireIntuneDevices only once
      you have confirmed from the report that the devices really are this person's.

      The note is additive - existing Notes content is preserved and the new line is
      appended, so this will not clobber notes another admin left.

    Run this from an admin workstation with the ActiveDirectory RSAT module installed,
    or from a domain controller. Exchange Online / Graph connections happen over the
    internet regardless of where the script runs.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [string]$SamAccountName,

    [switch]$CloudOnly,

    [string]$SharedMailboxOU,

    [switch]$SkipMailboxConversion,

    [string]$ManagerUpn,

    [switch]$AutoMapSharedMailbox,

    [switch]$SkipLicenseRemoval,

    [switch]$SkipDeviceStage,

    [switch]$RetireIntuneDevices,

    [switch]$SkipDeviceNote,

    # Clear the Intune primary user on each of the departed user's devices, so the hardware
    # can be handed to someone else without the terminated account still attached. ON by
    # default: devices circulate between staff here, and a stale primary user is the thing
    # that has to be remediated later. Pass -SkipClearDevicePrimaryUser to leave it alone.
    #
    # Note this only clears the RELATIONSHIP - the device stays enrolled, managed and
    # compliant. Nothing is retired or wiped. Reassigning later is a normal Intune action.
    # Side effect worth knowing: app/policy assignments targeted at the USER (rather than the
    # device) stop applying while there is no primary user, until someone new is assigned.
    [switch]$SkipClearDevicePrimaryUser,

    [switch]$SkipEntraSyncWait,

    [string]$EntraConnectServer,

    # PORTABLE BY DESIGN: reports land in a Reports\ subfolder next to THIS SCRIPT FILE, so the
    # whole package folder can be moved to a flash drive, a share, or a local disk and still work
    # with nothing to reconfigure. $PSScriptRoot is this file's own folder - deliberately NOT
    # '.\Reports' or $PWD, which resolve against whatever directory PowerShell happened to start
    # in (C:\Windows\System32 when launched from a shortcut or the Run box).
    # Override with -ReportPath to send reports to a central share instead; see .PARAMETER ReportPath.
    [string]$ReportPath,

    [int]$SyncWaitTimeoutSeconds = 300,

    [switch]$SkipSyncRecheck,

    [int]$SyncRecheckWaitSeconds = 90,

    [switch]$AutoInstallMissingModules
)

#region 0. Configuration (the organization preset)
# ---------------------------------------------------------------------------------------
# Preset for your own environment. Update this if your shared-mailbox /
# disabled-users OU ever changes. For any other organization, use the vendor-neutral
# Offboard-HybridUser-Neutral.ps1 instead and set its placeholder to their OU.
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

# Hostname of the server running Microsoft Entra Connect. Baked in so nobody has to remember
# -EntraConnectServer: without it the sync trigger silently no-ops and every AD-synced group
# gets flagged "Verify sync-removed" purely because Entra hasn't caught up yet. Confirm with
# Get-ADSyncScheduler ON that server. Set to $null if you trigger sync some other way.
$Script:DefaultEntraConnectServer = Get-EnvSetting -Name 'EntraConnectServer'

# Bump this whenever a meaningful behavior change ships. Logged as the first row of every
# report (and printed in the startup banner) so a saved CSV alone tells you whether a given
# run had a feature - no need to diff the .ps1 file against what's currently in this folder.
$Script:ScriptVersion = "2026-08-20.3 (device stage now CLEARS the Intune primary user by default so hardware can be reassigned - devices circulate between staff and a stale primary user was the thing needing remediation later; opt out with -SkipClearDevicePrimaryUser; clearing is a DELETE on the users/`$ref relationship, nothing is retired or wiped; Intune device lookup switched to /users/{id}/managedDevices via Invoke-MgGraphRequest - Microsoft's backend now rejects the userId filter with 'Unsupported parameter found in query'; device stage no longer reports 'none found' Success after a FAILED lookup, which was a false all-clear that could let an enrolled device slip through; worker paths quoted so folders with spaces work; Exchange now runs in an isolated child process via _ExoWorker.ps1 - EXO and Microsoft.Graph ship incompatible Microsoft.IdentityModel.Abstractions builds and cannot share one process, which was failing license removal and Entra cleanup; DL removals batched into a single Exchange sign-in; Connect-ExchangeOnline uses -DisableWAM where supported; assembly-conflict handler now names the assembly it actually caught instead of always blaming Graph; Graph module version preflight; fixed Exchange connection probe throwing NullReference and silently skipping mailbox conversion; device-stage module conflict now Skipped not Failed; Graph conflict distinguishes stale session from mismatched install; device stage: Intune + Entra device inventory, Notes flagging, opt-in retire; portable package - reports resolve to $PSScriptRoot\Reports; Entra Connect + report path defaults; DL removal by group ID; manager mailbox access; direct-vs-group license split; ConfirmImpact Medium)"
#endregion

if (-not $SharedMailboxOU)    { $SharedMailboxOU    = $Script:DefaultSharedMailboxOU }
if (-not $EntraConnectServer) { $EntraConnectServer = $Script:DefaultEntraConnectServer }

# One timestamp for the whole run so the .log and .csv for a given run share a filename stem
# (previously each called Get-Date separately and drifted by a few seconds, which made the
# transcript and report awkward to correlate after the fact).
$Script:RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# Resolve the package's own folder. $PSScriptRoot is normally correct, but fall back to the
# invocation path in the edge case where this file is dot-sourced rather than run with -File.
$Script:PackageRoot = $PSScriptRoot
if (-not $Script:PackageRoot) { $Script:PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Script:PackageRoot) { $Script:PackageRoot = (Get-Location).Path }

# Default reports to <package folder>\Reports so the package is self-contained and portable.
if (-not $ReportPath) { $ReportPath = Join-Path $Script:PackageRoot 'Reports' }

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

# ExchangeOnlineManagement and Microsoft.Graph.Authentication ship DIFFERENT builds of
# Microsoft.IdentityModel.Abstractions (EXO 3.10.1 -> 8.19.2.0, Graph 2.39.0 -> 8.18.0.0).
# .NET hosts only one version of an assembly per load context per process and the first
# module to load it wins, so whichever connects first pins MSAL for the whole session. The
# loser then fails with "Method not found: ... WithLogging(IIdentityLogger, Boolean)",
# because that overload carries the Abstractions type identity in its signature.
#
# No combination of current releases aligns those two, so this is NOT fixable by matching
# versions - it was tested to exhaustion on 2026-08-19/20. Instead, Exchange work runs in a
# child pwsh that never imports Graph, while this parent process keeps the Graph session and
# never imports EXO.
#
# Cost: one interactive Exchange sign-in per worker invocation. The offboarder batches its
# Exchange work so this happens at most twice per run (mailbox conversion, then DL removals).
function Invoke-ExoTask {
    param(
        [Parameter(Mandatory)] [array]$Operations,
        [string]$Label = 'Exchange operations'
    )

    $workerPath = Join-Path $PSScriptRoot '_ExoWorker.ps1'
    if (-not (Test-Path -LiteralPath $workerPath)) {
        return ,@([PSCustomObject]@{
            Stage = 'Exchange'; Item = 'n/a'; Action = 'Locate _ExoWorker.ps1'; Status = 'Failed'
            Detail = "Worker script not found at '$workerPath'. It ships alongside this script - re-copy the whole toolkit folder rather than the .ps1 on its own."
        })
    }

    $taskFile   = [System.IO.Path]::GetTempFileName()
    $resultFile = [System.IO.Path]::GetTempFileName()

    try {
        @{ Operations = $Operations } | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath $taskFile -Encoding UTF8

        # pwsh, not powershell: PS 5.1 resolves EXO out of the WindowsPowerShell module tree,
        # which is a separate install that drifts independently of the PS7 one.
        $pwshExe = (Get-Process -Id $PID).Path
        if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }

        # Each path is individually quoted: Start-Process joins -ArgumentList with spaces, so
        # an unquoted path containing one (e.g. "...\Main Scripts 080626\...") is parsed as
        # several arguments and pwsh rejects it.
        $argList = @(
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-File', ('"{0}"' -f $workerPath)
            '-TaskFile', ('"{0}"' -f $taskFile)
            '-ResultFile', ('"{0}"' -f $resultFile)
            '-DisableWAM'
        )
        if ($WhatIfPreference) { $argList += '-WhatIfMode' }

        Write-Host "`n--- $Label (isolated Exchange process) ---" -ForegroundColor Cyan
        $proc = Start-Process -FilePath $pwshExe -ArgumentList $argList -NoNewWindow -Wait -PassThru

        if (-not (Test-Path -LiteralPath $resultFile) -or
            -not (Get-Item -LiteralPath $resultFile).Length) {
            return ,@([PSCustomObject]@{
                Stage = 'Exchange'; Item = 'n/a'; Action = $Label; Status = 'Failed'
                Detail = "Exchange worker process exited with code $($proc.ExitCode) without writing results. Run _ExoWorker.ps1 directly with the same task file to see the raw error."
            })
        }

        $parsed = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        return ,@($parsed)
    }
    catch {
        return ,@([PSCustomObject]@{
            Stage = 'Exchange'; Item = 'n/a'; Action = $Label; Status = 'Failed'
            Detail = "Could not run the Exchange worker: $($_.Exception.Message)"
        })
    }
    finally {
        Remove-Item -LiteralPath $taskFile, $resultFile -Force -ErrorAction SilentlyContinue
    }
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
            # Pull the assembly name out of the message FIRST and report on that, rather than
            # assuming every load failure here is the Graph one. On 2026-08-20 this block
            # confidently reported "Microsoft Graph assembly conflict" for a failure whose
            # actual assembly was Microsoft.PackageManagement 3.0.0.1 (two PackageManagement
            # versions installed), and sent an afternoon of troubleshooting the wrong way.
            $failedAsm = $null
            if ($_.Exception.Message -match "Could not load file or assembly '([^,']+)") {
                $failedAsm = $Matches[1]
            }
            $isGraphAsm = $failedAsm -and $failedAsm -match '^Microsoft\.Graph'

            if (($_.Exception.Message -match 'Assembly with same name is already loaded' -or
                 $_.Exception.Message -match 'Could not load file or assembly') -and -not $isGraphAsm) {
                # An assembly conflict, but NOT a Graph one. Say so plainly and point at the
                # module that actually owns the assembly, instead of prescribing a Graph fix.
                $other  = "Assembly conflict while importing '$Name' - but the assembly that failed to load is "
                $other += "NOT a Microsoft.Graph one.`n`n"
                $other += "  $($_.Exception.Message)`n`n"
                $other += "  Assembly named in the error : $(if ($failedAsm) { $failedAsm } else { '(could not parse - read the message above)' })`n`n"
                $other += "This is the same class of problem as the Graph conflict - .NET hosts only one version of "
                $other += "an assembly per process - but the fix is to find which MODULE ships the assembly above and "
                $other += "remove its duplicate versions. Check all three module trees, not just one:`n"
                $other += "  `$env:PSModulePath -split ';'`n"
                $other += "  Get-Module <ModuleName> -ListAvailable | Select-Object Name,Version,Path`n`n"
                $other += "Note PowerShell 7 includes the Windows PowerShell tree "
                $other += "(C:\Program Files\WindowsPowerShell\Modules) on PSModulePath, and a stale copy there wins "
                $other += "over a correct one elsewhere. Reopen PowerShell after cleaning up - the bad assembly stays "
                $other += "loaded until you do."
                throw $other
            }

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

# Reports default to <package folder>\Reports. That folder is not always writable - a read-only
# share, a write-protected flash drive, or a full disk all fail here - so probe it and fall back
# to a local folder rather than aborting an in-progress offboarding over a reporting problem.
# Say so loudly, because the run record then won't travel with the package.
$Script:ReportPathFallbackUsed = $false
try {
    if (-not (Test-Path $ReportPath)) {
        New-Item -Path $ReportPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    # Prove we can actually write, not just resolve the path (read-only share rights are common).
    $probe = Join-Path $ReportPath ".writeprobe_$PID"
    Set-Content -Path $probe -Value 'probe' -ErrorAction Stop
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
}
catch {
    $Script:ReportPathFallbackUsed = $true
    $originalReportPath = $ReportPath
    $ReportPath = Join-Path $env:LOCALAPPDATA 'OffboardingReports'
    if (-not (Test-Path $ReportPath)) {
        New-Item -Path $ReportPath -ItemType Directory -Force | Out-Null
    }
    Write-Warning ("Could not write to '$originalReportPath' ($($_.Exception.Message)). " +
                   "Falling back to '$ReportPath'. The package folder is read-only or full - " +
                   "COPY THE REPORT OUT OF THE FALLBACK FOLDER so the run record isn't lost.")
}

$transcriptFile = Join-Path $ReportPath "$SamAccountName`_$Script:RunStamp.log"
Start-Transcript -Path $transcriptFile -Append | Out-Null
if ($Script:ReportPathFallbackUsed) {
    Add-Result "Script" "ReportPath" "Fallback" "Warning" "Package folder not writable; report written to $ReportPath instead"
}

Write-Host ("=== Offboarding $SamAccountName" + $(if ($CloudOnly) { " (cloud-only - AD steps assumed already done)" }) + "  |  script v$Script:ScriptVersion ===") -ForegroundColor Cyan
Write-Host "Reports will be saved to: $ReportPath" -ForegroundColor DarkCyan

#region 1. Load / verify modules (installs on demand instead of assuming they're present)
# Wrapped so a missing-module throw closes the transcript instead of leaving it running - the
# early throws further down already do this, module loading was the one path that didn't.
try {
Ensure-Module -Name 'ActiveDirectory' -IsWindowsFeature -ManualInstallHint (
    "Windows 10/11: Settings > Optional Features > Add a feature > 'RSAT: Active Directory " +
    "Domain Services and Lightweight Directory Tools' (or run, as admin: " +
    "Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0). " +
    "Windows Server: Install-WindowsFeature RSAT-AD-PowerShell."
)
Ensure-Module -Name 'ExchangeOnlineManagement' -ManualInstallHint "Install-Module ExchangeOnlineManagement -Scope CurrentUser"
Test-GraphModuleVersions

Ensure-Module -Name 'Microsoft.Graph.Users' -ManualInstallHint "Install-Module Microsoft.Graph.Users -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Groups' -ManualInstallHint "Install-Module Microsoft.Graph.Groups -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Identity.DirectoryManagement' -ManualInstallHint "Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Identity.SignIns' -ManualInstallHint "Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser"
}
catch {
    Add-Result "Modules" "Prerequisites" "Ensure-Module" "Failed" $_.Exception.Message
    $results | Export-Csv -Path (Join-Path $ReportPath "$SamAccountName`_$Script:RunStamp.csv") -NoTypeInformation
    Stop-Transcript | Out-Null
    throw
}
#endregion

#region 1b. Validate configuration now that ActiveDirectory is loaded
if (-not $SharedMailboxOU) {
    Stop-Transcript | Out-Null
    throw "-SharedMailboxOU was not provided and no default is set. Pass -SharedMailboxOU 'OU=...,DC=...,DC=...'."
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

# Resolve who gets access to the converted shared mailbox. Explicit -ManagerUpn wins; otherwise
# fall back to the departing user's AD Manager attribute. Converting a mailbox to shared without
# granting anyone access preserves the mail and leaves nobody able to open it, which is the most
# common complaint after an offboarding.
if (-not $ManagerUpn) {
    try {
        $adUserMgr = Get-ADUser -Identity $SamAccountName -Properties Manager
        if ($adUserMgr.Manager) {
            $mgrObj = Get-ADUser -Identity $adUserMgr.Manager -Properties UserPrincipalName
            if ($mgrObj.UserPrincipalName) {
                $ManagerUpn = $mgrObj.UserPrincipalName
                Write-Host "Manager resolved from AD: $ManagerUpn" -ForegroundColor DarkCyan
                Add-Result "Lookup" $SamAccountName "Resolve manager from AD" "Success" $ManagerUpn
            }
        }
        else {
            Add-Result "Lookup" $SamAccountName "Resolve manager from AD" "Skipped" "No Manager attribute set on the AD account; pass -ManagerUpn to grant mailbox access"
        }
    }
    catch {
        Add-Result "Lookup" $SamAccountName "Resolve manager from AD" "Warning" $_.Exception.Message
    }
}
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
    # Runs in a child process - see Invoke-ExoTask for why Exchange cannot share this
    # session with Microsoft.Graph. AutoMapping is off by default: it force-mounts the
    # mailbox in the manager's Outlook profile, which is often unwanted on a departed
    # employee's mailbox. Pass -AutoMapSharedMailbox for the old behaviour.
    if ($PSCmdlet.ShouldProcess($upn, "Set-Mailbox -Type Shared (isolated Exchange process)")) {
        $exoResults = Invoke-ExoTask -Label "Mailbox conversion" -Operations @(
            @{
                Type        = 'ConvertMailbox'
                Upn         = $upn
                ManagerUpn  = $ManagerUpn
                AutoMapping = [bool]$AutoMapSharedMailbox
            }
        )
        foreach ($r in $exoResults) {
            Add-Result $r.Stage $r.Item $r.Action $r.Status $r.Detail
        }
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
            Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "GroupMember.ReadWrite.All", "Directory.Read.All", "DeviceManagementManagedDevices.ReadWrite.All", "Device.Read.All" -NoWelcome
        }
        # -UserId rather than -Filter: an OData filter breaks on apostrophe surnames (o'brien@...).
        $mgUserForLicense = Get-MgUser -UserId $upn -Property Id, UserPrincipalName, LicenseAssignmentStates -ErrorAction SilentlyContinue
        if (-not $mgUserForLicense) {
            Add-Result "Entra-Licenses" $upn "Remove licenses" "Failed" "User not found in Entra ID - hybrid sync may not have completed yet"
        }
        else {
            # Set-MgUserLicense is atomic: if ANY SkuId in -RemoveLicenses came from group-based
            # licensing, the whole call fails and nothing is removed. Split them so directly-assigned
            # licenses always come off, and group-inherited ones are reported for manual handling
            # (they can only be removed by taking the user out of the licensing group).
            $states     = @($mgUserForLicense.LicenseAssignmentStates)
            $directSkus = @($states | Where-Object { -not $_.AssignedByGroup } | Select-Object -ExpandProperty SkuId -Unique)
            $groupSkus  = @($states | Where-Object { $_.AssignedByGroup }     | Select-Object -ExpandProperty SkuId -Unique)

            # Friendly SKU names for the report - GUIDs alone are useless six months later.
            $skuLookup = @{}
            try {
                foreach ($s in (Get-MgSubscribedSku -All -ErrorAction Stop)) { $skuLookup[$s.SkuId] = $s.SkuPartNumber }
            } catch { }
            $nameOf = { param($id) if ($skuLookup.ContainsKey($id)) { $skuLookup[$id] } else { $id } }

            if ($groupSkus.Count -gt 0) {
                $groupNames = ($groupSkus | ForEach-Object { & $nameOf $_ }) -join ", "
                Add-Result "Entra-Licenses" $upn "Group-inherited license(s)" "Warning" `
                    "Cannot be removed per-user: $groupNames. Remove the user from the licensing group instead."
            }

            if ($directSkus.Count -eq 0) {
                Add-Result "Entra-Licenses" $upn "Remove licenses" "Skipped" "No directly-assigned licenses currently assigned"
            }
            else {
                $skuNames = ($directSkus | ForEach-Object { & $nameOf $_ }) -join ", "
                if ($PSCmdlet.ShouldProcess($upn, "Remove license(s): $skuNames")) {
                    try {
                        Set-MgUserLicense -UserId $mgUserForLicense.Id -AddLicenses @() -RemoveLicenses $directSkus | Out-Null
                        Add-Result "Entra-Licenses" $upn "Set-MgUserLicense (remove)" "Success" $skuNames
                    }
                    catch {
                        Add-Result "Entra-Licenses" $upn "Set-MgUserLicense (remove)" "Failed" "$skuNames - $($_.Exception.Message)"
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
        Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "GroupMember.ReadWrite.All", "Directory.Read.All", "DeviceManagementManagedDevices.ReadWrite.All", "Device.Read.All" -NoWelcome
    }

    # -UserId rather than -Filter: an OData filter breaks on apostrophe surnames (o'brien@...).
    $mgUser = Get-MgUser -UserId $upn -Property Id, UserPrincipalName -ErrorAction SilentlyContinue
    if (-not $mgUser) {
        Add-Result "Entra" $upn "Get-MgUser" "Failed" "User not found in Entra ID - hybrid sync may not have completed yet"
    }
    else {
        $memberOf = Get-MgUserMemberOf -UserId $mgUser.Id -All
        $syncedGroupsToRecheck = New-Object System.Collections.Generic.List[Object]
        # Distribution lists / mail-enabled security groups needing Exchange to remove the
        # member. Gathered during the loop, handed to the Exchange worker in one batch after
        # it, so the run costs at most one extra interactive sign-in rather than one per DL.
        $pendingDlRemovals     = New-Object System.Collections.Generic.List[Object]

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
                    # removal is inconsistent for these, so Exchange Online has to do it.
                    #
                    # QUEUED, not executed here: Exchange runs in a child process (see
                    # Invoke-ExoTask), and spawning one per group would mean an interactive
                    # sign-in per DL. Collect them all and hand the batch over once the loop
                    # has finished. Order does not matter for DL membership.
                    $pendingDlRemovals.Add([PSCustomObject]@{
                        GroupId   = $groupId
                        GroupName = $groupName
                    })
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

        #region 8a. Distribution list removals (batched, isolated Exchange process)
        # Everything the loop above queued goes over in a single worker invocation - one
        # Exchange sign-in for the whole set rather than one per group.
        if ($pendingDlRemovals.Count -gt 0) {
            $dlResults = Invoke-ExoTask -Label "Distribution list removals ($($pendingDlRemovals.Count) group(s))" -Operations @(
                @{
                    Type   = 'RemoveDistributionGroupMembers'
                    Upn    = $upn
                    Groups = @($pendingDlRemovals | ForEach-Object {
                        @{ GroupId = $_.GroupId; GroupName = $_.GroupName }
                    })
                }
            )
            foreach ($r in $dlResults) {
                Add-Result $r.Stage $r.Item $r.Action $r.Status $r.Detail
            }
        }
        #endregion

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

        #region 9b. Devices - inventory, flag, and optionally retire
        # Placed after sign-in has been blocked and sessions revoked, so anything found here
        # can no longer authenticate as this user regardless of what we do with the device.
        #
        # Deliberately fail-soft: this stage runs after the destructive AD/Exchange work is
        # already done, so a missing module, a missing Graph scope or an Intune API hiccup
        # must never take the whole run down. Every failure is recorded and the script
        # carries on to the report.
        if ($SkipDeviceStage) {
            Add-Result "Devices" "n/a" "Device stage" "Skipped" "-SkipDeviceStage specified"
        }
        else {
            Write-Host "`n--- Devices (Intune + Entra) ---" -ForegroundColor Cyan
            try {
                # Loaded here rather than in region 1 on purpose: anyone who hasn't installed
                # Microsoft.Graph.DeviceManagement yet keeps the exact pre-device behaviour
                # instead of having offboarding refuse to start.
                $deviceModuleReady = $true
                if (-not (Get-Module -Name Microsoft.Graph.DeviceManagement)) {
                    if (Get-Module -ListAvailable -Name Microsoft.Graph.DeviceManagement) {
                        try {
                            Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop
                        }
                        catch {
                            # A Graph assembly conflict here is a module-version problem on the
                            # workstation, not an offboarding failure - the AD and Entra work above
                            # already succeeded. Record it as Skipped with the cause so the run
                            # isn't marked failed for something unrelated to this user.
                            $deviceModuleReady = $false
                            $devErr = $_.Exception.Message
                            if ($devErr -match 'Assembly with same name is already loaded' -or
                                $devErr -match 'Could not load file or assembly .*Microsoft\.Graph') {
                                $devLoaded = @(Get-Module Microsoft.Graph* | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', '
                                Add-Result "Devices" "Microsoft.Graph.DeviceManagement" "Import module" "Skipped" (
                                    "Graph assembly version conflict - Intune devices were not enumerated. This is a module-version " +
                                    "problem on this workstation, not a problem with the offboarding: everything above completed. " +
                                    "Loaded: $devLoaded. Compare installed versions with " +
                                    "'Get-Module Microsoft.Graph* -ListAvailable | Select Name,Version | Sort Name,Version' and align them.")
                                Write-Warning "Intune device check skipped - Graph module version conflict. The rest of the offboarding completed."
                            }
                            else {
                                Add-Result "Devices" "Microsoft.Graph.DeviceManagement" "Import module" "Skipped" $devErr
                            }
                        }
                    }
                    else {
                        $deviceModuleReady = $false
                    }
                }

                # Entra-registered / joined devices come from Microsoft.Graph.Users, which is
                # already loaded, so report those even if the Intune module is absent.
                $entraDevices = @()
                try {
                    $entraDevices = @(Get-MgUserRegisteredDevice -UserId $mgUser.Id -All -ErrorAction Stop)
                }
                catch {
                    Add-Result "Devices" $upn "Get-MgUserRegisteredDevice" "Failed" $_.Exception.Message
                }

                if ($entraDevices.Count -eq 0) {
                    Add-Result "Devices" $upn "Entra registered devices" "Success" "None found"
                }
                foreach ($d in $entraDevices) {
                    $props    = $d.AdditionalProperties
                    $dName    = if ($props['displayName']) { $props['displayName'] } else { $d.Id }
                    $joinType = if ($props['trustType']) { $props['trustType'] } else { 'unknown' }
                    $lastOn   = if ($props['approximateLastSignInDateTime']) { $props['approximateLastSignInDateTime'] } else { 'unknown' }
                    Add-Result "Devices" $dName "Entra registered device (found)" "Warning" (
                        "trustType: $joinType | last sign-in: $lastOn | Entra objectId: $($d.Id) - " +
                        "left in place for the manual checklist (Autopilot/Entra object removal is not automated)")
                }

                if (-not $deviceModuleReady) {
                    Add-Result "Devices" "Microsoft.Graph.DeviceManagement" "Intune device stage" "Skipped" (
                        "Module not installed, so Intune devices were not enumerated. Install it with: " +
                        "Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser")
                    Write-Warning "Microsoft.Graph.DeviceManagement isn't installed - Intune devices were not checked. Entra-registered devices above are still reported."
                }
                else {
                    # Check the scope before calling, so a consent gap reads as a clear
                    # instruction rather than a raw 403 buried in the CSV.
                    $ctxScopes = @((Get-MgContext).Scopes)
                    $needScope = 'DeviceManagementManagedDevices.Read.All'
                    $haveScope = ($ctxScopes -contains $needScope) -or
                                 ($ctxScopes -contains 'DeviceManagementManagedDevices.ReadWrite.All')
                    if (-not $haveScope) {
                        Add-Result "Devices" "Graph scope" "Intune device stage" "Failed" (
                            "Current Graph session lacks $needScope. Run Disconnect-MgGraph and re-run " +
                            "this script so it can consent to the device scopes.")
                    }
                    else {
                        $intuneDevices = @()
                        $deviceQueryOk = $false
                        try {
                            # /users/{id}/managedDevices, NOT /deviceManagement/managedDevices
                            # with -Filter "userId eq '...'". Microsoft's Intune backend
                            # (api-version 2025-07-09 onward) rejects that filter outright with
                            # "Unsupported parameter found in query" - seen 2026-08-20.
                            #
                            # Invoke-MgGraphRequest rather than a typed cmdlet: this endpoint's
                            # wrapper moves between SDK submodules across releases, and this call
                            # needs only Microsoft.Graph.Authentication, which is already loaded
                            # for the session. Returns hashtables, so properties are read by key.
                            $uri  = "https://graph.microsoft.com/v1.0/users/$($mgUser.Id)/managedDevices"
                            $page = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
                            $collected = New-Object System.Collections.Generic.List[Object]
                            while ($true) {
                                foreach ($d in @($page.value)) { $collected.Add($d) }
                                if (-not $page.'@odata.nextLink') { break }
                                $page = Invoke-MgGraphRequest -Method GET -Uri $page.'@odata.nextLink' -ErrorAction Stop
                            }
                            # Invoke-MgGraphRequest returns hashtables with camelCase keys,
                            # whereas the typed cmdlets returned objects with PascalCase
                            # properties. Normalise here so everything downstream - the report
                            # lines, the Notes append, the retire call - is untouched.
                            $intuneDevices = @($collected | ForEach-Object {
                                [PSCustomObject]@{
                                    Id               = $_.id
                                    DeviceName       = $_.deviceName
                                    OperatingSystem  = $_.operatingSystem
                                    OsVersion        = $_.osVersion
                                    SerialNumber     = $_.serialNumber
                                    ComplianceState  = $_.complianceState
                                    LastSyncDateTime = $_.lastSyncDateTime
                                    Notes            = $_.notes
                                }
                            })
                            $deviceQueryOk = $true
                        }
                        catch {
                            # A 404 means the user has NO managed devices - Graph returns
                            # NotFound for this navigation property rather than an empty
                            # collection. Normal for most users; not a failure.
                            $status = $null
                            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                            if ($status -eq 404 -or $_.Exception.Message -match 'NotFound') {
                                $deviceQueryOk = $true
                                $intuneDevices = @()
                            }
                            else {
                                Add-Result "Devices" $upn "Enumerate Intune managed devices" "Failed" (
                                    "Could not enumerate Intune devices for this user, so any enrolled device is " +
                                    "UNREVIEWED - check Intune manually before considering this offboarding complete. " +
                                    "Error: $($_.Exception.Message)")
                            }
                        }

                        # Only claim "none found" if the query actually succeeded. Reporting
                        # Success off an empty list after a failed lookup is a false all-clear,
                        # and would let an enrolled device slip through an offboarding.
                        if ($deviceQueryOk -and $intuneDevices.Count -eq 0) {
                            Add-Result "Devices" $upn "Intune managed devices" "Success" "None found with this user as primary user"
                        }

                        foreach ($dev in $intuneDevices) {
                            $label = if ($dev.DeviceName) { $dev.DeviceName } else { $dev.Id }
                            Add-Result "Devices" $label "Intune device (found)" "Warning" (
                                "OS: $($dev.OperatingSystem) $($dev.OsVersion) | serial: $($dev.SerialNumber) | " +
                                "compliance: $($dev.ComplianceState) | last sync: $($dev.LastSyncDateTime) | " +
                                "managedDeviceId: $($dev.Id)")

                            # --- flag it in the Notes field (default) ---
                            if ($SkipDeviceNote) {
                                Add-Result "Devices" $label "Set Intune note" "Skipped" "-SkipDeviceNote specified"
                            }
                            elseif ($PSCmdlet.ShouldProcess($label, "Append offboarding note to Intune device")) {
                                try {
                                    $stamp    = Get-Date -Format 'yyyy-MM-dd'
                                    $noteLine = "[OFFBOARDED $stamp] Primary user $upn was offboarded on $stamp by $($env:USERNAME). Device NOT retired or wiped - confirm current owner before reassigning or retiring. Report: $SamAccountName`_$Script:RunStamp.csv"
                                    $existing = $dev.Notes
                                    $newNotes = if ([string]::IsNullOrWhiteSpace($existing)) { $noteLine }
                                                else { ($existing.TrimEnd() + "`r`n" + $noteLine) }
                                    Update-MgDeviceManagementManagedDevice -ManagedDeviceId $dev.Id -Notes $newNotes -ErrorAction Stop
                                    Add-Result "Devices" $label "Set Intune note" "Success" "Offboarding note appended; prior notes preserved"
                                }
                                catch {
                                    Add-Result "Devices" $label "Set Intune note" "Failed" $_.Exception.Message
                                }
                            }

                            # --- clear the primary user (default on) ---
                            # Primary user is a RELATIONSHIP, not a settable property, so this
                            # is a DELETE on the $ref rather than a PATCH. Only on beta - the
                            # v1.0 managedDevice type does not expose the users navigation.
                            if ($SkipClearDevicePrimaryUser) {
                                Add-Result "Devices" $label "Clear primary user" "Skipped" `
                                    "-SkipClearDevicePrimaryUser specified - $upn left as primary user on this device"
                            }
                            elseif ($PSCmdlet.ShouldProcess($label, "Clear Intune primary user ($upn)")) {
                                try {
                                    $refUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$($dev.Id)')/users/`$ref"
                                    Invoke-MgGraphRequest -Method DELETE -Uri $refUri -ErrorAction Stop | Out-Null
                                    Add-Result "Devices" $label "Clear primary user" "Success" (
                                        "$upn removed as primary user - device stays enrolled and managed, and can now be " +
                                        "reassigned. User-targeted app/policy assignments will not apply until a new " +
                                        "primary user is set.")
                                }
                                catch {
                                    Add-Result "Devices" $label "Clear primary user" "Failed" (
                                        "$upn is still the primary user on this device - clear it in Intune manually " +
                                        "(Devices > $label > Properties) before reassigning the hardware. " +
                                        "Error: $($_.Exception.Message)")
                                }
                            }

                            # --- retire, only if explicitly asked for ---
                            if (-not $RetireIntuneDevices) {
                                Add-Result "Devices" $label "Retire device" "Skipped" "-RetireIntuneDevices not specified - device left enrolled (default)"
                            }
                            elseif ($PSCmdlet.ShouldProcess($label, "RETIRE Intune device (removes company data)")) {
                                try {
                                    Invoke-MgRetireDeviceManagementManagedDevice -ManagedDeviceId $dev.Id -ErrorAction Stop
                                    Add-Result "Devices" $label "Retire device" "Success" "Retire command queued - completes next time the device checks in"
                                }
                                catch {
                                    Add-Result "Devices" $label "Retire device" "Failed" $_.Exception.Message
                                }
                            }
                        }
                    }
                }
            }
            catch {
                # Belt and braces: the stage is informational, never worth aborting for.
                Add-Result "Devices" $upn "Device stage" "Failed" $_.Exception.Message
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
$reportFile = Join-Path $ReportPath "$SamAccountName`_$Script:RunStamp.csv"
$results | Export-Csv -Path $reportFile -NoTypeInformation

Write-Host "`n=== Summary for $SamAccountName ===" -ForegroundColor Cyan
$results | Format-Table Stage, Item, Action, Status -AutoSize

$deviceRows = $results | Where-Object { $_.Stage -eq 'Devices' -and $_.Action -like '*(found)*' }
if ($deviceRows) {
    Write-Host "`n$($deviceRows.Count) device(s) still associated with this user:" -ForegroundColor Yellow
    $deviceRows | ForEach-Object { Write-Host "  - $($_.Item)  [$($_.Action)]" -ForegroundColor Yellow }
    Write-Host "  These were flagged, not retired. Confirm the current owner before acting." -ForegroundColor Yellow
}

$failures = $results | Where-Object { $_.Status -in @('Failed', 'Warning', 'TimedOut') }
if ($failures) {
    Write-Warning "$($failures.Count) item(s) need manual review - see $reportFile"
}
else {
    Write-Host "All steps completed cleanly. Report: $reportFile" -ForegroundColor Green
}

Stop-Transcript | Out-Null
#endregion

