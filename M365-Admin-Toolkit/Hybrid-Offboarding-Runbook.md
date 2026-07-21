Hybrid User Offboarding — Runbook

*Portable template: automated disable, mailbox conversion, OU move, and full group-membership cleanup across on-prem Active Directory and Entra ID (Microsoft 365 / Intune). No organization-specific values are hard-coded.*

Script: Offboard-HybridUser.ps1

*Location: `Offboard-HybridUser.ps1` lives in `access-profile/`; this runbook lives in `docs/`. The identity-health audit scripts it pairs with live in `entra/` and `security/`.*

1\. What this solves

Typical offboarding disables the AD account, converts the mailbox to shared, and moves the account to a shared-mailbox OU manually — then requires a separate manual pass through Intune and the Microsoft 365 admin center to find and remove cloud group memberships. This script automates all of it in one run, including the part that's easy to miss: it distinguishes groups that are synced from on-prem AD from groups that only exist in the cloud, and routes each removal to the system that actually owns it.

2\. The hybrid sync nuance (read this first)

In a hybrid Entra Connect environment, group membership has two possible sources of truth, and mixing them up is the main way “remove from all groups” automation fails silently:

- Synced groups — created in on-prem AD, mirrored up to Entra ID by Entra Connect (OnPremisesSyncEnabled = true on the Entra side). Entra treats these as read-only. Removing a user via Microsoft Graph does nothing lasting: the next sync cycle just re-adds them from AD. These must be changed in AD.

- Cloud-only groups — created directly in Entra ID or the M365 admin center (Microsoft 365 Groups, cloud security groups, and most Intune-assigned groups). AD has no record of these at all. These can only be changed via Microsoft Graph (or Exchange Online for mail-enabled groups).

The script handles this by removing local memberships in AD first, optionally triggering an Entra Connect delta sync, then querying Microsoft Graph for the user's remaining group memberships and checking each group's OnPremisesSyncEnabled flag before deciding how to remove it. If a synced group still shows the user as a member after a sync, the script flags it as a warning instead of silently failing — that usually means the AD-side removal didn't take, or the sync hasn't caught up yet.

3\. What the script does, in order

1.  Looks up the AD user and disables the account (Disable-ADAccount).

2.  Moves the AD object into the shared-mailbox / disabled-users OU you specify (Move-ADObject).

3.  Converts the mailbox to a shared mailbox via Exchange Online (Set-Mailbox -Type Shared).

4.  Removes every Entra ID license currently assigned to the user (Set-MgUserLicense), on by default — skip with -SkipLicenseRemoval. Runs after the mailbox conversion above so a license isn't pulled out from under an in-progress conversion.

5.  Enumerates and removes every local AD group membership (Get-ADPrincipalGroupMembership / Remove-ADGroupMember), skipping the primary group (usually Domain Users), which requires reassigning PrimaryGroupID rather than a normal removal.

6.  Optionally triggers an Entra Connect delta sync on your sync server and waits (polls) for it to finish, so step 7 sees up-to-date data.

7.  Connects to Microsoft Graph, enumerates the user's remaining group memberships, and for each: skips + flags synced groups (already handled in AD), skips dynamic membership groups (rule-based, can't be manually removed), removes cloud-only security/M365 groups via Graph, and removes cloud-only mail-enabled groups (distribution lists) via Exchange Online, since Graph's handling of plain distribution lists is inconsistent.

8.  Waits -SyncRecheckWaitSeconds (default 90s, skip with -SkipSyncRecheck), then re-checks every synced group flagged in step 7 and logs whether it actually cleared or is still showing — closes the loop instead of leaving a static warning you'd have to separately re-verify later.

9.  Revokes all active Entra sign-in sessions/refresh tokens and sets AccountEnabled = false in Entra directly — this is immediate, whereas the AD disable only reaches Entra on the next sync cycle.

10. Writes a CSV report and a full transcript log for every action taken, skipped, or failed, so you have an audit trail per offboarded user.

Steps 1, 2, and 5 (the on-prem AD steps) are skipped entirely when -CloudOnly is specified - see section 8.

4\. Finding your environment-specific values

This script has no hard-coded OU, domain, or tenant. Section "0. Configuration" near the top of the .ps1 has one placeholder to set (or override per-run with a parameter). Here's exactly where to find each value:

Shared Mailbox / disabled-users OU (distinguished name)

- GUI: open Active Directory Users and Computers (dsa.msc) → View menu → check "Advanced Features" → right-click the target OU → Properties → Attribute Editor tab → find distinguishedName → copy its value.

- PowerShell: Get-ADOrganizationalUnit -Filter \* \| Select-Object Name, DistinguishedName — look for the OU you use for disabled/shared-mailbox accounts.

Paste that value into \$Script:DefaultSharedMailboxOU near the top of the script (section 0), or pass it every run with -SharedMailboxOU. The script validates the OU actually exists before doing anything, and will error clearly if the placeholder was never replaced.

Entra Connect server (optional — only needed to auto-trigger a sync)

- This is the hostname of whichever server has Microsoft Entra Connect (formerly Azure AD Connect) installed — check Programs and Features on your likely sync server, or ask whoever manages hybrid identity.

- Confirm you have the right box by running, ON that server: Get-ADSyncScheduler.

If you don't know it, or don't want to grant PowerShell remoting rights to it, just omit -EntraConnectServer — the script still runs correctly, it just won't trigger a sync itself (see section 10, known limitations).

5\. Prerequisites

PowerShell modules — the script checks, it doesn't assume

The script does not assume ActiveDirectory, Exchange Online, or Microsoft Graph modules are already installed. On each run it checks for every required module and:

- Imports it if already installed.

- For PSGallery modules (Exchange Online, Microsoft.Graph.\*): prompts to install it for the current user on the spot (or installs automatically if you pass -AutoInstallMissingModules).

- For ActiveDirectory (RSAT — not a gallery module): stops with the exact command/menu path to install it, since that has to be done as a Windows feature, not via Install-Module.

|                                              |                                                      |                                                            |
|----------------------------------------------|------------------------------------------------------|------------------------------------------------------------|
| **Module**                                   | **Purpose**                                          | **Source**                                                 |
| ActiveDirectory                              | Account disable, OU move, local group removal        | RSAT (Windows feature)                                     |
| ExchangeOnlineManagement                     | Shared mailbox conversion; DL member removal         | PSGallery                                                  |
| Microsoft.Graph.Users                        | Look up Entra user, revoke sessions, disable sign-in | PSGallery                                                  |
| Microsoft.Graph.Groups                       | Enumerate/remove cloud group memberships             | PSGallery                                                  |
| Microsoft.Graph.Identity.DirectoryManagement | Group metadata (sync status, type)                   | PSGallery                                                  |
| Microsoft.Graph.Identity.SignIns             | Revoke-MgUserSignInSession                           | PSGallery                                                  |
| Microsoft.Graph.Users.Actions                | Set-MgUserLicense (license removal)                  | PSGallery — only checked if -SkipLicenseRemoval is not set |

To install everything up front instead of being prompted mid-run:

Install-Module ExchangeOnlineManagement, Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.SignIns -Scope CurrentUser

ActiveDirectory (RSAT) still has to be added separately — Windows 10/11: Settings \> Optional Features \> Add a feature \> "RSAT: Active Directory Domain Services and Lightweight Directory Tools". Windows Server: Install-WindowsFeature RSAT-AD-PowerShell.

Permissions

Run as (or connect as) an account/app registration with:

- On-prem: delegated rights to disable accounts, move objects, and modify group membership in the relevant OUs (standard AD delegation, not Domain Admin).

- Exchange Online: Recipient Management role (or equivalent) to convert mailboxes and edit distribution list membership.

- Microsoft Graph scopes: User.ReadWrite.All, Group.ReadWrite.All, GroupMember.ReadWrite.All, Directory.Read.All.

For unattended/scheduled use, register an Entra app with these scopes granted as application permissions and connect with Connect-MgGraph using a certificate rather than interactive/delegated login. Do not embed a client secret in the script or store it in plain text.

6\. Parameters

|                            |              |                                                                                                                                                                                                                              |
|----------------------------|--------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Parameter**              | **Required** | **Description**                                                                                                                                                                                                              |
| -SamAccountName            | Yes          | AD SamAccountName of the user being offboarded.                                                                                                                                                                              |
| -CloudOnly                 | No           | Skip the on-prem AD steps (disable, OU move, AD group removal) and only run the cloud side. Use to retry cloud-only steps (most commonly license removal) for a user already fully offboarded on the AD side. See section 8. |
| -SharedMailboxOU           | No\*         | Distinguished name of the OU to move the account to. \*Required unless you've set \$Script:DefaultSharedMailboxOU in section 0 of the script. The script validates the OU exists before proceeding.                          |
| -SkipMailboxConversion     | No           | Skip the shared-mailbox conversion (e.g. the user had no mailbox).                                                                                                                                                           |
| -SkipLicenseRemoval        | No           | Opt-out switch. By default every assigned Entra ID license is removed after the mailbox conversion. Pass this to leave licenses in place (e.g. a temporary leave rather than a permanent offboarding).                       |
| -SkipEntraSyncWait         | No           | Skip triggering/waiting for a delta sync before checking cloud groups.                                                                                                                                                       |
| -EntraConnectServer        | No           | Hostname of your Entra Connect server, used to trigger the delta sync remotely.                                                                                                                                              |
| -ReportPath                | No           | Folder for the CSV report and transcript log. Defaults to .\OffboardingReports.                                                                                                                                              |
| -SyncWaitTimeoutSeconds    | No           | How long to wait for the delta sync before giving up. Defaults to 300.                                                                                                                                                       |
| -SkipSyncRecheck           | No           | Skip the second-pass re-check of synced groups that still showed the user as a member on first evaluation. Off by default.                                                                                                   |
| -SyncRecheckWaitSeconds    | No           | How long to wait before the second-pass re-check above. Defaults to 90 seconds.                                                                                                                                              |
| -AutoInstallMissingModules | No           | Install missing PSGallery modules automatically instead of prompting.                                                                                                                                                        |
| -WhatIf                    | No           | Preview every change without making it — run this first on any new user.                                                                                                                                                     |

7\. Running it

First-time setup: open the script, find section "0. Configuration" near the top, and either replace the OU placeholder with your real value, or plan to always pass -SharedMailboxOU explicitly. Then preview before running for real:

.\Offboard-HybridUser.ps1 -SamAccountName jsmith \`  
-SharedMailboxOU "OU=Shared Mailboxes,DC=yourdomain,DC=com" \`  
-EntraConnectServer AADC01 -WhatIf

Then run for real (drop -WhatIf):

.\Offboard-HybridUser.ps1 -SamAccountName jsmith \`  
-SharedMailboxOU "OU=Shared Mailboxes,DC=yourdomain,DC=com" \`  
-EntraConnectServer AADC01

If you've set the default OU in section 0, you can drop -SharedMailboxOU from the command entirely:

.\Offboard-HybridUser.ps1 -SamAccountName jsmith -EntraConnectServer AADC01

Leaving licenses in place instead (e.g. a temporary leave rather than a permanent offboarding):

.\Offboard-HybridUser.ps1 -SamAccountName jsmith -SkipLicenseRemoval

The script will prompt to connect to Exchange Online and Microsoft Graph the first time each is needed in the session (interactive sign-in), unless you've already connected with a service account/certificate beforehand. If any module is missing, it will prompt to install it (or install automatically with -AutoInstallMissingModules) — except ActiveDirectory/RSAT, which it will explain how to add instead.

8\. -CloudOnly: retrying just the cloud steps

If a run's AD-side work already succeeded (account disabled, moved, AD groups removed) but the cloud side needs another pass - most commonly because license removal hit a permissions/scope issue, or the Graph connection in that session had a narrower set of scopes than required - re-run with -CloudOnly instead of starting over. It skips Disable-ADAccount, Move-ADObject, and AD group removal entirely (each logged as "Skipped" in the report) and goes straight to mailbox conversion (unless -SkipMailboxConversion), license removal, sync trigger/wait, cloud group cleanup + recheck, and session revoke.

.\Offboard-HybridUser.ps1 -SamAccountName jsmith -CloudOnly

Safe to re-run as many times as needed: mailbox conversion on an already-shared mailbox is a no-op, license removal on a user with no remaining licenses just logs "no licenses currently assigned," and cloud groups the user is already out of simply won't appear in the next membership check. If the previous run failed on license removal specifically because of a Graph permissions/scope issue, make sure you're either starting a fresh PowerShell session or running Disconnect-MgGraph first - -CloudOnly reuses an existing Graph connection if one is already active in that session, and won't request broader scopes if a narrower one is already connected.

9\. Reading the output

Each run produces two files in -ReportPath: a timestamped .csv (one row per action: stage, item, action, status, detail) and a matching .log transcript. Status values are Success, Skipped, Failed, Warning, or TimedOut. Anything other than Success/Skipped is worth a manual look — Warning specifically means “a synced group still shows this user as a member after sync,” which usually means either the AD removal in step 5 didn't take, or the sync in step 6 hasn't propagated yet. That's exactly what the step-8 second-pass re-check is for: give it -SyncRecheckWaitSeconds (default 90s) and it'll log a follow-up row showing whether the group actually cleared or is still stuck. The very first row of every report is always "Script / Version" — check it against this runbook's known feature set if a run's behavior looks unexpected. Re-running the script is safe (idempotent): groups already removed simply won't appear in the next Get-ADPrincipalGroupMembership / Get-MgUserMemberOf call, and licenses already removed simply won't show up in the next Get-MgUserLicenseDetail call.

10\. Known limitations / things to watch

- Intune device actions (retire/wipe) are intentionally out of scope — this script handles account disable, mailbox conversion, license removal, and group membership only.

- License removal is on by default (step 4) — it strips every license currently assigned, with no way to selectively keep one SKU. Pass -SkipLicenseRemoval if the user should keep their licenses (e.g. a leave of absence). There's no automatic re-assignment if this turns out to be a mistake; you'd reassign the license manually. If license removal failed on a prior run, re-run with -CloudOnly rather than the full script (see section 8).

- Dynamic groups (rule-based membership in Entra) can't be “removed from” directly — membership is computed from the rule. If a dynamic group's rule includes this user (e.g. by department or attribute), removing the account from other groups won't remove it from that one; you'll need to change the qualifying attribute or exclude the user from the rule. The script detects and skips these automatically instead of failing on them.

- Removing a user from a Microsoft 365 Group they own but didn't create can fail if they're the only owner — the script will log this as Failed rather than silently drop ownership; reassign ownership manually first if this comes up.

- The primary AD group (normally Domain Users) is intentionally skipped — removing it requires reassigning PrimaryGroupID to another group first, which changes the user's default group and is left as a manual/deliberate step.

- If -EntraConnectServer is omitted, cloud-only group removal still happens correctly, but a just-removed synced group may still appear as a Warning until your next scheduled sync runs — that's expected, not a bug. The step-8 recheck still runs (it just waits on the clock rather than a triggered sync), so it's worth leaving -SkipSyncRecheck off even without an Entra Connect server.

- ActiveDirectory (RSAT) can't be auto-installed like the other modules — it's a Windows feature, not a PSGallery package. The script detects this and gives you the exact install command instead of failing silently.

- -CloudOnly reuses an already-connected Microsoft Graph session as-is if one exists in the current PowerShell window - it won't upgrade a narrower-scoped connection from an earlier script. Start a fresh session (or Disconnect-MgGraph) first if a previous run's license removal failed due to insufficient scope.

11\. Security notes

- Prefer a dedicated offboarding service account with the minimum delegated AD rights and a certificate-based Graph app registration over an individual admin's interactive credentials.

- Never hard-code credentials, client secrets, or tokens in the script. Use certificate auth for Connect-MgGraph and Windows-integrated/interactive auth for Exchange Online and AD.

- Store the CSV/transcript reports somewhere access-controlled — they contain group names and membership history for the offboarded user.

- Review the -WhatIf output before the first live run in any new OU or against any new group naming convention, since a typo in -SharedMailboxOU will throw rather than silently do nothing.

- -AutoInstallMissingModules is convenient for repeat/scheduled use but means the script can reach out to PSGallery and install packages unattended — fine for a controlled admin workstation, worth a second thought on a shared or production-adjacent box.

- License removal (Microsoft.Graph.Users.Actions / Set-MgUserLicense) requires the same Graph scopes as the group cleanup steps — no extra consent is needed if you've already granted User.ReadWrite.All and the others in section 5.

12\. Auditing existing shared-mailbox accounts

Audit-SharedMailboxOU.ps1 checks everyone already sitting in the Shared Mailbox OU against the state the offboarding script is supposed to leave them in. Use it to catch stragglers from before this automation existed, or from partial/failed offboarding runs.

What it checks, per account

- AD account still enabled (it shouldn't be).

- Leftover local AD group memberships (anything besides the primary group).

- Mailbox type in Exchange Online (should be Shared, not a regular mailbox).

- Entra ID AccountEnabled (should be false).

- Leftover Entra group memberships — synced groups are flagged as "fix in AD", cloud-only groups are flagged as "fix via Graph/Exchange Online", same sync-aware logic as the offboarding script.

Report-only by default, remediation is opt-in

Run it with no switches and it only reports — zero changes, safe to run anytime. Add -Remediate to have it fix what it finds, reusing the exact same removal logic as the offboarding script (Remove-ADGroupMember, Set-Mailbox -Type Shared, Update-MgUser -AccountEnabled:\$false, Remove-MgGroupMemberByRef / Remove-DistributionGroupMember). -Remediate supports -WhatIf so you can preview fixes before committing.

.\Audit-SharedMailboxOU.ps1 -SharedMailboxOU "OU=Shared Mailboxes,DC=yourdomain,DC=com"

.\Audit-SharedMailboxOU.ps1 -SharedMailboxOU "OU=Shared Mailboxes,DC=yourdomain,DC=com" -Remediate -WhatIf

.\Audit-SharedMailboxOU.ps1 -SharedMailboxOU "OU=Shared Mailboxes,DC=yourdomain,DC=com" -Remediate

Output matches the offboarding script's pattern: a timestamped CSV (User, Category, Action, Status, Detail) and a transcript log in -ReportPath (defaults to .\AuditReports), plus a console summary of how many accounts were audited vs. flagged.

- A synced group that still shows up in Entra right after -Remediate removed it in AD isn't a bug — it just hasn't synced yet. Re-run the audit after the next Entra Connect cycle.

- "Info" status rows (no mailbox found, not yet synced to Entra) are informational, not failures — they don't count toward the flagged total.
