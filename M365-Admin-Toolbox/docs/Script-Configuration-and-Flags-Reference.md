Script Configuration & Flags — Quick Reference (Neutral)

*A cross-cutting cheat sheet for the vendor-neutral scripts and the shared universal audit scripts: where each script's environment-specific values are defined, whether it reads a JSON file, and what every flag/switch does. This is the portable, vendor-neutral edition - see a tenant-preset edition you maintain privately for the tenant-preset scripts instead. Nothing organization-specific is named here, so this doc is safe to share outside your organization. This is a companion to the per-script runbooks, not a replacement for them.*

Covers: Offboard-HybridUser.ps1, Audit-SharedMailboxOU.ps1, Export-UserAccessProfile-Neutral.ps1, New-UserFromAccessProfile-Neutral.ps1, plus the shared Audit-StaleAccounts, Audit-LicenseWaste, Audit-PrivilegedAccess, Audit-SharedMailboxPermissions Updated: July 2026

1\. Folder layout

Scripts and runbooks are organized into three folders:

- Neutral/ — every -Neutral.ps1 script and its runbook. This document lives here.

- TenantPreset/ — the tenant-preset twin of every Neutral script, plus its own runbook and its own edition of this reference doc.

- Shared/ — the four identity-health audit scripts (Audit-StaleAccounts, Audit-LicenseWaste, Audit-PrivilegedAccess, Audit-SharedMailboxPermissions) and cross-cutting docs like the Identity Health Audits runbook and this reference, since none of those are organization-specific or need a tenant-preset twin.

2\. Where each script's configuration actually lives

Every script that needs an environment-specific default (an OU path, a UPN suffix, a usage-location code) defines it the same way: a block near the very top of the .ps1 file, marked \#region 0. Configuration, using plain PowerShell \$Script: variables. There is no external config file - to change a default, open the .ps1 in a text editor and edit the value directly in that block, then save. In the Neutral scripts specifically, every one of these defaults is still a CHANGE-ME placeholder until you set it - that's intentional, so the script fails fast and tells you exactly what's missing rather than silently running against the wrong environment.

|                                       |                      |                                                                                   |                                                      |
|---------------------------------------|----------------------|-----------------------------------------------------------------------------------|------------------------------------------------------|
| **Script (Neutral folder)**           | **Has a Section 0?** | **Variable(s) defined there**                                                     | **Out-of-the-box value**                             |
| Offboard-HybridUser.ps1       | Yes                  | \$Script:DefaultSharedMailboxOU \$Script:ScriptVersion                            | OU=CHANGE-ME,DC=CHANGE-ME,DC=CHANGE-ME (placeholder) |
| Audit-SharedMailboxOU.ps1     | Yes                  | \$Script:DefaultSharedMailboxOU                                                   | OU=CHANGE-ME,DC=CHANGE-ME,DC=CHANGE-ME (placeholder) |
| Export-UserAccessProfile-Neutral.ps1  | No                   | n/a - fully dynamic, reads whatever template user you point it at                 | n/a                                                  |
| New-UserFromAccessProfile-Neutral.ps1 | Yes (fallbacks only) | \$Script:DefaultNewUserOU \$Script:DefaultUpnSuffix \$Script:DefaultUsageLocation | All three are CHANGE-ME placeholders                 |

The four Shared-folder audit scripts (Audit-StaleAccounts, Audit-LicenseWaste, Audit-PrivilegedAccess, Audit-SharedMailboxPermissions) have no Section 0 at all - every setting is an ordinary PowerShell parameter default, portable as-is with no placeholders to replace. Override any of it per-run with the matching parameter.

3\. Which scripts use JSON, and for what

Only one JSON file format exists in this suite: the access profile written by Export-UserAccessProfile-Neutral.ps1 and read by New-UserFromAccessProfile-Neutral.ps1. It is a data snapshot, not a configuration file - it captures what a specific template user's access looked like at export time, not settings that control how the scripts behave.

Access profile JSON schema

|               |                                                                                |                                                                                                       |
|---------------|--------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------|
| **Field**     | **Type**                                                                       | **Captured from**                                                                                     |
| ProfileName   | string                                                                         | -ProfileName param, or the SamAccountName if omitted                                                  |
| SourceUser    | string (UPN)                                                                   | The template user's UPN - also supplies the UPN domain for new hires                                  |
| SourceUserOU  | string (DN)                                                                    | The template user's own OU - becomes the new hire's default -TargetOU                                 |
| UsageLocation | string                                                                         | The template user's Entra UsageLocation - becomes the new hire's default                              |
| ExportedDate  | string (timestamp)                                                             | When Export-UserAccessProfile-Neutral.ps1 was run                                                     |
| ADGroups      | array of {Name, DistinguishedName}                                             | Template user's local AD group memberships (primary group excluded)                                   |
| EntraGroups   | array of {GroupId, GroupName, IsSynced, IsDynamic, IsMailEnabled, IsM365Group} | Template user's Entra group memberships, tagged so the apply-side script knows how to handle each one |
| Licenses      | array of {SkuId, SkuPartNumber}                                                | Template user's assigned Entra ID licenses                                                            |

No other Neutral script reads or writes JSON.

4\. Every flag/switch, Neutral scripts + shared audits

Preview / safety

|          |                                                                                                                             |                                                                                                                                                                                                          |
|----------|-----------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Flag** | **Appears on**                                                                                                              | **What it does**                                                                                                                                                                                         |
| -WhatIf  | Offboard-HybridUser.ps1, Audit-SharedMailboxOU.ps1 (with -Remediate), New-UserFromAccessProfile-Neutral.ps1 | Standard PowerShell ShouldProcess preview - shows what would happen without making any change. Read-only lookups (account-existence, OU validation) still run for real since they don't modify anything. |

Retry / resume (-CloudOnly)

|                                       |                                                                                    |                                                                                               |
|---------------------------------------|------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------|
| **Script**                            | **What -CloudOnly skips**                                                          | **What still runs**                                                                           |
| Offboard-HybridUser.ps1       | Disable-ADAccount, Move-ADObject, local AD group removal (steps 1, 2, 5)           | Mailbox conversion, license removal, sync wait, cloud group cleanup + recheck, session revoke |
| New-UserFromAccessProfile-Neutral.ps1 | SamAccountName generation, New-ADUser, local AD group provisioning (steps 1, 3, 4) | Sync wait, UsageLocation, cloud group add, license assignment                                 |

In both cases -CloudOnly means "the on-prem AD side already happened (or was already correct), just (re)do the cloud side" - but which specific AD steps it skips differs between offboarding (disable/move/remove) and provisioning (create/add). Both require -SamAccountName explicitly.

Skip / opt-out switches

|                        |                                                                        |                                                                                                                     |
|------------------------|------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| **Flag**               | **Appears on**                                                         | **What it does**                                                                                                    |
| -SkipMailboxConversion | Offboard-HybridUser.ps1                                        | Leaves the mailbox as-is instead of converting to Shared.                                                           |
| -SkipLicenseRemoval    | Offboard-HybridUser.ps1                                        | Leaves all Entra licenses in place instead of removing them. License removal is ON by default; this is the opt-out. |
| -SkipEntraSyncWait     | Offboard-HybridUser.ps1, New-UserFromAccessProfile-Neutral.ps1 | Skips triggering/waiting for an Entra Connect delta sync before the cloud steps run.                                |
| -SkipSyncRecheck       | Offboard-HybridUser.ps1                                        | Skips the second-pass re-check of synced groups. Off by default (the recheck runs unless you pass this).            |

Remediation / write-back

|            |                                   |                                                                                                                                                 |
|------------|-----------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| **Flag**   | **Appears on**                    | **What it does**                                                                                                                                |
| -Remediate | Audit-SharedMailboxOU.ps1 | The ONLY flag that turns an audit script from report-only into one that fixes what it finds. Off by default; supports -WhatIf to preview first. |

Important: Audit-StaleAccounts, Audit-LicenseWaste, Audit-PrivilegedAccess, and Audit-SharedMailboxPermissions (all in the Shared folder) have NO -Remediate switch at all - permanently report-only by design.

Convenience / environment

|                                             |                                     |                                                                                                                      |
|---------------------------------------------|-------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| **Flag**                                    | **Appears on**                      | **What it does**                                                                                                     |
| -AutoInstallMissingModules                  | Every script                        | Installs any missing PSGallery module automatically instead of prompting. Never applies to ActiveDirectory/RSAT.     |
| -ExcludeOU                                  | Audit-StaleAccounts.ps1 (Shared)    | Skips one or more OUs entirely (e.g. wherever you park already-offboarded accounts) so they don't get flagged again. |
| -SearchBase                                 | Audit-StaleAccounts.ps1 (Shared)    | Limits the scan to a specific OU instead of the whole domain.                                                        |
| -AdPrivilegedGroups / -EntraPrivilegedRoles | Audit-PrivilegedAccess.ps1 (Shared) | Override the built-in default group/role lists with your own custom admin groups/roles.                              |

5\. Quick lookup: what's report-only vs. what changes things

- Always read-only, no exceptions: Export-UserAccessProfile-Neutral.ps1, Audit-StaleAccounts, Audit-LicenseWaste, Audit-PrivilegedAccess, Audit-SharedMailboxPermissions.

- Read-only by default, opt-in to write with -Remediate: Audit-SharedMailboxOU.ps1.

- Makes changes by design, supports -WhatIf to preview first: Offboard-HybridUser.ps1, New-UserFromAccessProfile-Neutral.ps1.
