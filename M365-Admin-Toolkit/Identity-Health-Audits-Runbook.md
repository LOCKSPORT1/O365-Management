Identity Health Audits — Runbook

*Four read-only audit scripts that catch drift between what your offboarding/onboarding automation is supposed to keep clean and what's actually sitting in Active Directory and Entra ID: stale enabled accounts, wasted licenses, privileged-access gaps, and leftover shared-mailbox permissions. All four are portable/vendor-neutral — nothing your tenant-specific is hard-coded, so these are safe to reuse or share as-is.*

Scripts: Audit-StaleAccounts.ps1, Audit-LicenseWaste.ps1, Audit-PrivilegedAccess.ps1, Audit-SharedMailboxPermissions.ps1 Prepared for: IT Operations Updated: July 2026

*Location: `Audit-StaleAccounts.ps1` and `Audit-LicenseWaste.ps1` live in `entra/`; `Audit-PrivilegedAccess.ps1` lives in `security/`; `Audit-SharedMailboxPermissions.ps1` lives in `exchange/`. This runbook lives in `docs/`. None of them carry environment-specific defaults (see section 2 for why).*

1\. What this set of audits solves

The offboarding, onboarding, and shared-mailbox-OU audit scripts documented in the other runbooks all assume someone tells them when to run — a departing employee, a new hire, a known-messy OU. Nothing up to this point periodically checks whether the environment has quietly drifted out of the state those scripts are supposed to maintain: an account nobody remembered to offboard, a license still burning a seat on a disabled user, a privileged role with no MFA behind it, or a Full Access grant on a shared mailbox that should have been revoked months ago. These four scripts close that gap. Every one of them is report-only — none of them change anything — so they're safe to run anytime, including on a recurring schedule.

2\. The four scripts, at a glance

|                                    |                                                                                                     |                                                            |
|------------------------------------|-----------------------------------------------------------------------------------------------------|------------------------------------------------------------|
| **Script**                         | **Checks**                                                                                          | **Primary risk it catches**                                |
| Audit-StaleAccounts.ps1            | Enabled AD accounts with no AD or Entra activity beyond a threshold                                 | Offboarding that never got triggered                       |
| Audit-LicenseWaste.ps1             | Entra licenses on disabled or dormant accounts, plus a per-SKU seat summary                         | Paying for licenses nobody's using                         |
| Audit-PrivilegedAccess.ps1         | AD admin-group and Entra admin-role membership: disabled/stale members, missing MFA, guest accounts | A compromised password reaching a Global Admin with no MFA |
| Audit-SharedMailboxPermissions.ps1 | Full Access / Send As / Send on Behalf grants on every shared mailbox, tenant-wide                  | Lingering mailbox access left over from offboarding        |

A design note on the last one: unlike Audit-SharedMailboxOU.ps1 (documented in the offboarding runbook), Audit-SharedMailboxPermissions.ps1 queries Exchange Online directly for every mailbox of type SharedMailbox tenant-wide, rather than scoping by AD OU. That makes it a single universal script instead of a tenant-preset/neutral pair — there's no organization-specific OU path to bake a default for, and scanning by mailbox type actually catches more (any shared mailbox, regardless of where its AD object lives, if it has one at all).

3\. Audit-StaleAccounts.ps1

Flags AD accounts that are still enabled but haven't shown activity — in AD or Entra, whichever is more recent — within -InactiveDays (default 90). Takes the more recent of the two systems' timestamps specifically to avoid false-flagging a hybrid user who's active in one system but whose other system's signal looks stale.

|                            |              |                                                                                                                                            |
|----------------------------|--------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| **Parameter**              | **Required** | **Description**                                                                                                                            |
| -InactiveDays              | No           | Days of no activity before flagging. Defaults to 90.                                                                                       |
| -SearchBase                | No           | AD OU to limit the scan to. Omit to scan the whole domain.                                                                                 |
| -ExcludeOU                 | No           | One or more OUs to skip entirely (e.g. your shared-mailbox OU, since accounts there are already offboarded and expected to look inactive). |
| -ReportPath                | No           | Folder for the CSV report and transcript. Defaults to .\AuditReports.                                                                      |
| -AutoInstallMissingModules | No           | Install missing PSGallery modules automatically instead of prompting.                                                                      |

.\Audit-StaleAccounts.ps1 -InactiveDays 60 -ExcludeOU "OU=Shared Mailboxes,OU=Users,DC=contoso,DC=com"

LastLogonTimestamp in AD only replicates every 9-14 days by design, so it's an approximation on its own — that's exactly why this script also checks Entra's sign-in activity and takes whichever is fresher. A flagged account isn't automatically safe to offboard: service accounts, break-glass accounts, and leave-of-absence users can legitimately look dormant. Review the list, then run the offboarding script (or -CloudOnly if it was already partially handled) against anything confirmed genuinely stale.

4\. Audit-LicenseWaste.ps1

Flags Entra ID licenses assigned to disabled accounts (the single most common and highest-confidence finding — a disabled account can never use its license again) and, more softly, licenses on enabled accounts with no sign-in in -InactiveDays (default 90). Also prints a per-SKU purchased/assigned/available summary so you can see seat waste at a glance, separate from the per-user findings.

|                            |              |                                                                                                                                                               |
|----------------------------|--------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Parameter**              | **Required** | **Description**                                                                                                                                               |
| -InactiveDays              | No           | Days of no sign-in before an enabled, licensed account is flagged as a soft waste candidate. Defaults to 90. Disabled accounts are always flagged regardless. |
| -ReportPath                | No           | Folder for the CSV report and transcript. Defaults to .\AuditReports.                                                                                         |
| -AutoInstallMissingModules | No           | Install missing PSGallery modules automatically instead of prompting.                                                                                         |

.\Audit-LicenseWaste.ps1 -InactiveDays 30

The per-SKU summary needs Organization.Read.All — if that scope isn't granted, per-user flagging still works fine but the SKU summary section is skipped and noted as unavailable in the report. Disabled-account findings are safe to act on immediately (remove the license, or re-run the offboarding script with -CloudOnly if it wasn't already done); dormant-but-enabled findings deserve a quick human check first.

5\. Audit-PrivilegedAccess.ps1

Audits membership of your highest-value AD groups (Domain Admins, Enterprise Admins, Schema Admins by default) and Entra ID directory roles (Global Administrator, Privileged Role Administrator, User Administrator, License Administrator by default), and flags: disabled or stale members, guest (external) accounts holding a privileged role, and — the single highest-priority finding this script can produce — privileged accounts with no MFA method registered at all.

|                            |              |                                                                                                                                                          |
|----------------------------|--------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Parameter**              | **Required** | **Description**                                                                                                                                          |
| -AdPrivilegedGroups        | No           | AD group names to audit. Defaults to Domain Admins, Enterprise Admins, Schema Admins.                                                                    |
| -EntraPrivilegedRoles      | No           | Entra directory role display names to audit. Defaults to Global Administrator, Privileged Role Administrator, User Administrator, License Administrator. |
| -InactiveDays              | No           | Staleness threshold for privileged accounts. Defaults to 60 (tighter than the general 90-day default).                                                   |
| -ReportPath                | No           | Folder for the CSV report and transcript. Defaults to .\AuditReports.                                                                                    |
| -AutoInstallMissingModules | No           | Install missing PSGallery modules automatically instead of prompting.                                                                                    |

\# Default groups/roles  
.\Audit-PrivilegedAccess.ps1

\# Custom Entra role list  
.\Audit-PrivilegedAccess.ps1 -EntraPrivilegedRoles "Global Administrator", "Exchange Administrator", "Security Administrator"

The MFA check confirms a method is registered (authenticator app, phone, FIDO2, etc.) — it cannot confirm MFA is actually enforced on every sign-in for that account. Cross-check against your Conditional Access policies if you need enforcement, not just registration. A flagged group/role membership isn't automatically wrong either — some automation accounts legitimately need standing privileged access. The goal is making sure that's a deliberate, reviewed state rather than something nobody's looked at.

6\. Audit-SharedMailboxPermissions.ps1

Enumerates every shared mailbox tenant-wide and lists Full Access, Send As, and Send on Behalf grants, flagging any held by an account that's since been disabled. Exchange doesn't automatically strip a user's permissions over OTHER mailboxes when their own account is disabled, so this is exactly the kind of thing that silently accumulates after every offboarding cycle.

|                            |              |                                                                       |
|----------------------------|--------------|-----------------------------------------------------------------------|
| **Parameter**              | **Required** | **Description**                                                       |
| -ReportPath                | No           | Folder for the CSV report and transcript. Defaults to .\AuditReports. |
| -AutoInstallMissingModules | No           | Install missing PSGallery modules automatically instead of prompting. |

.\Audit-SharedMailboxPermissions.ps1

Group-based grants are reported as informational only, not flagged — the script doesn't expand group membership to check every member individually, so if you need that depth, audit the group's own membership separately. A grantee that can't be resolved in AD or Entra at all ("NotFound") usually means the account was hard-deleted rather than disabled; those entries are generally safe to remove since there's no account left for them to matter to.

7\. Prerequisites

PowerShell modules

All four scripts follow the same on-demand module pattern as the rest of this automation suite: check first, import if present, prompt to install if missing (or auto-install with -AutoInstallMissingModules), and explain exactly how to add ActiveDirectory/RSAT since that's a Windows feature, not a PSGallery package.

|                                              |                                                                                                         |                        |
|----------------------------------------------|---------------------------------------------------------------------------------------------------------|------------------------|
| **Module**                                   | **Used by**                                                                                             | **Source**             |
| ActiveDirectory                              | StaleAccounts, PrivilegedAccess (required); SharedMailboxPermissions (optional, used opportunistically) | RSAT (Windows feature) |
| ExchangeOnlineManagement                     | SharedMailboxPermissions                                                                                | PSGallery              |
| Microsoft.Graph.Users                        | All four scripts                                                                                        | PSGallery              |
| Microsoft.Graph.Identity.DirectoryManagement | LicenseWaste, PrivilegedAccess                                                                          | PSGallery              |
| Microsoft.Graph.Identity.SignIns             | PrivilegedAccess (authentication methods / MFA check)                                                   | PSGallery              |

Required Graph scopes, combined

- User.Read.All — all four scripts

- AuditLog.Read.All — StaleAccounts, LicenseWaste, PrivilegedAccess (unlocks sign-in activity)

- Organization.Read.All — LicenseWaste (per-SKU seat summary only; per-user checks work without it)

- RoleManagement.Read.Directory — PrivilegedAccess (enumerating directory role membership)

- UserAuthenticationMethod.Read.All — PrivilegedAccess (the MFA registration check)

None of these scripts need write scopes — every one of them is read-only by design, so there's nothing to accidentally change by running them.

8\. Running these on a schedule

Since none of these scripts modify anything, they're good candidates for a recurring schedule rather than something you have to remember to run manually. A sensible cadence: Audit-StaleAccounts and Audit-LicenseWaste weekly, Audit-PrivilegedAccess weekly or even daily given how high-value the MFA finding is, and Audit-SharedMailboxPermissions monthly (permission drift accumulates more slowly). Each script writes a fresh timestamped CSV + transcript to its -ReportPath every run, so a scheduled task just needs to point at a consistent report folder and someone (or an alert rule watching for new "Flagged" rows) to review the output periodically.

9\. Reading the output

All four scripts share the same CSV shape: a Timestamp column plus script-specific identity columns (User/Mailbox), a Category, a Status, and a Detail. Status is always one of OK, Flagged, Info, or Failed. Info rows are things worth knowing but not necessarily acting on (a group-based permission grant, a SKU summary line, an Entra role that's never been assigned in this tenant). Failed rows mean the script couldn't check something — usually a missing Graph scope — and are worth a second look at your module/permission setup rather than the account itself. Flagged is the only status that represents an actual finding to review.

10\. Known limitations

- None of these scripts remediate anything automatically — every finding is meant for human review before action, unlike Audit-SharedMailboxOU.ps1 (documented separately), which does support an opt-in -Remediate switch for its narrower scope.

- Audit-StaleAccounts and Audit-PrivilegedAccess rely on AD's LastLogonTimestamp, which only replicates every 9-14 days by design - both scripts pair it with Entra's real-time sign-in activity to reduce false positives, but a very recent logon on a single DC may not show up in either signal yet.

- Audit-PrivilegedAccess's MFA check only confirms a method is registered, not that MFA is enforced on every sign-in - Conditional Access policy review is a separate step.

- Audit-SharedMailboxPermissions doesn't expand group-based permission grants to check individual members - audit the group's own membership directly if you need that depth.

- Audit-LicenseWaste's per-SKU summary requires Organization.Read.All - without it, per-user waste flagging still works, but the summary section is skipped.

- All four scripts assume the account running them has read access to the relevant AD OUs / Entra scopes - a partial-permission run will show up as Failed rows rather than silently omitting data, so check the Detail column on any Failed row before trusting a clean report.

11\. Security notes

- These scripts only ever need read scopes/roles - there's no reason to grant them anything beyond what's listed in section 7, even for scheduled/unattended runs.

- Store the CSV/transcript reports somewhere access-controlled - Audit-PrivilegedAccess's output in particular is effectively a map of your highest-value accounts and their MFA gaps.

- Treat a "no MFA on a privileged account" finding as urgent - remediate it (enforce MFA registration, or remove the standing privileged role if it's not actually needed day-to-day) before the next scheduled run rather than batching it with lower-priority findings.

- Prefer a dedicated read-only service account or app registration (certificate-based Graph auth) for scheduled/unattended runs, same guidance as the rest of this automation suite.
