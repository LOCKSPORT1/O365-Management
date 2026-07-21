New Hire Provisioning — Runbook

*Portable template: clone a template user's local AD groups, Entra ID groups, and Microsoft 365 licenses into a reusable JSON access profile, then apply that profile to provision a new hire — either by creating their AD account from scratch, or by finishing cloud provisioning for an account that already exists. No organization-specific values are hard-coded.*

Scripts: Export-UserAccessProfile.ps1 and New-UserFromAccessProfile.ps1

*Location: both scripts live in `access-profile/`; this runbook lives in `docs/`. If you maintain a private tenant-preset copy with your real values baked in, everything here applies to it equally.*

1\. Two scripts in this package

|                                       |                                                                                                                                                                                                                                                 |
|---------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Script**                            | **Role**                                                                                                                                                                                                                                        |
| Export-UserAccessProfile.ps1  | Read-only. Points at an existing "template" user (e.g. a current Engineering team member) and writes a JSON file capturing their local AD groups, Entra ID groups, assigned licenses, OU, and usage location. Never modifies the template user. |
| New-UserFromAccessProfile.ps1 | Applies a JSON profile to a new hire: creates the AD account (or targets an existing one with -CloudOnly), adds the AD groups, waits for Entra Connect sync, then sets usage location, adds cloud-only groups, and assigns the licenses.        |

Run Export once per role/template (or whenever that template user's access changes), then reuse the resulting profile file for every new hire in that role.

2\. What this solves

Manually recreating a new hire's access — figuring out which security groups, distribution lists, and Microsoft 365 licenses a role actually needs — is slow and error-prone, especially across a hybrid AD/Entra environment where some groups are AD-synced and others are cloud-only. This pair of scripts captures a known-good template user's access once into a portable file, then replays it onto a new hire automatically, including creating the AD account itself with an auto-generated logon name and a one-time temporary password.

3\. Export-UserAccessProfile: what it captures

1.  Looks up the template user in AD (by -SamAccountName) and records their own OU (parsed from their distinguished name) — used later as the new hire's default OU.

2.  Enumerates the template user's local AD group memberships (Get-ADPrincipalGroupMembership), excluding their primary group (usually Domain Users, not meaningful to copy).

3.  Connects to Microsoft Graph and looks up the template user's Entra ID object, including their UsageLocation (e.g. "US") — Graph won't assign a license to a user with no usage location set, so this is captured for later.

4.  Enumerates the template user's Entra ID group memberships and tags each one Synced / Dynamic / Mail-enabled / M365 Group, so New-UserFromAccessProfile.ps1 knows how to handle each one when applying the profile.

5.  Records every Entra ID license SKU currently assigned to the template user (SkuId + human-readable SkuPartNumber).

6.  Writes everything to a JSON file (default folder .\AccessProfiles) for later use.

This script only reads data — it never modifies the template user in any way. Review the resulting JSON before using it: it reflects exactly what the template user has, including anything that might be a personal exception rather than a true role requirement.

4\. New-UserFromAccessProfile: what it does, in order

7.  If -SamAccountName wasn't given, generates one from -GivenName/-Surname as first-initial + surname (John Smith -\> JSmith), appending an incrementing number on collision (JSmith2, JSmith3, ...).

8.  Loads the JSON profile and resolves -TargetOU, the UPN domain, and -UsageLocation using a cascading default: explicit param wins, then the value captured in the profile from the template user, then this script's own section-0 fallback.

9.  Creates the new on-prem AD user (New-ADUser) in the resolved OU, enabled, with a temporary password the user must change at first logon. (Skipped entirely under -CloudOnly — see section 6.)

10. Adds the new user to every local AD group listed in the profile. (Also skipped under -CloudOnly.)

11. Optionally triggers an Entra Connect delta sync and waits for it, so the new account and its AD group memberships propagate to Entra before the cloud steps run.

12. Connects to Microsoft Graph, sets the new user's UsageLocation, then for each Entra group in the profile: synced groups are left alone (already handled by the matching AD group above), dynamic membership groups are skipped (can't be manually added — the user only joins automatically if they match the group's own rule), and cloud-only groups are added directly via Graph.

13. Assigns every license SKU listed in the profile, one Set-MgUserLicense call per SKU so a single SKU running out of seats doesn't block the others.

14. Emits a per-user CSV report of every action taken and its outcome, and (unless -CloudOnly) displays the auto-generated temporary password once in the console.

5\. SamAccountName auto-generation

If you don't pass -SamAccountName, it's generated from -GivenName and -Surname as first initial + surname — John Smith becomes JSmith. If that name is already taken in AD, an incrementing number is appended (JSmith2, JSmith3, ...) until an unused name is found, respecting the 20-character SamAccountName limit. Pass -SamAccountName explicitly any time you want to override this (and it's required, not generated, when using -CloudOnly — see section 6).

6\. -CloudOnly: finishing provisioning for an existing account

Sometimes the AD side of a run succeeds but the cloud side fails — most commonly because Entra Connect hadn't synced the brand-new account yet when the script reached the Graph steps. Re-running the script normally in that situation throws "AD user already exists", since it assumes it's creating someone new. Pass -CloudOnly -SamAccountName \<name\> instead to skip AD account creation and AD group provisioning entirely (both logged as "Skipped" in the report) and pick up from the Entra Connect sync step onward against the existing account. -GivenName/-Surname aren't needed in this mode, and the new user's UPN is read directly off the existing AD account rather than being constructed.

.\New-UserFromAccessProfile.ps1 -ProfilePath .\AccessProfiles\Engineering-NewHire.json -SamAccountName CLister -CloudOnly

Safe to re-run: cloud groups and licenses the user already has simply won't be re-added/re-assigned as new actions, and usage location will just be confirmed again.

7\. Cascading defaults: OU, UPN domain, usage location

For -TargetOU, the UPN domain, and -UsageLocation, resolution always follows the same order: an explicit parameter you pass on the command line wins first; otherwise the value captured in the profile from the template user is used; otherwise this script's own section-0 fallback applies. In practice this means most runs need nothing beyond -ProfilePath, -GivenName, and -Surname — the new hire lands in the same OU, gets the same email domain, and gets the same usage location as the template user automatically.

|               |                                                      |                                                 |
|---------------|------------------------------------------------------|-------------------------------------------------|
| **Value**     | **Section 0 fallback (out of the box)**              | **Normally comes from**                         |
| TargetOU      | OU=CHANGE-ME,DC=CHANGE-ME,DC=CHANGE-ME (placeholder) | Profile's SourceUserOU (template user's own OU) |
| UPN domain    | CHANGE-ME.com (placeholder)                          | Domain portion of the profile's SourceUser UPN  |
| UsageLocation | CHANGE-ME (placeholder)                              | Profile's UsageLocation (template user's own)   |

This script has no hard-coded OU, domain, tenant, or usage location — every section-0 fallback above is a placeholder. In practice, as long as every profile you use has SourceUserOU, SourceUser, and UsageLocation set (Export always captures these), you'll rarely fall back to section 0 at all. If you do want real fallbacks for your environment, edit \$Script:DefaultNewUserOU, \$Script:DefaultUpnSuffix, and \$Script:DefaultUsageLocation near the top of the script — see the .NOTES block in the script itself for exactly how to look up each value (Get-ADOrganizationalUnit -Filter \*, an existing user's UserPrincipalName, and your tenant's standard usage location).

8\. Prerequisites

PowerShell modules — checked, not assumed

Neither script assumes ActiveDirectory or Microsoft Graph modules are already installed. Each checks for every required module and imports it if present, offers to install PSGallery modules for the current user (or installs automatically with -AutoInstallMissingModules), or explains how to add ActiveDirectory (RSAT), since that's a Windows feature, not a gallery package.

|                                              |                                                                                                  |                        |
|----------------------------------------------|--------------------------------------------------------------------------------------------------|------------------------|
| **Module**                                   | **Used by**                                                                                      | **Source**             |
| ActiveDirectory                              | Both scripts — user/group lookups, New-ADUser, Add-ADGroupMember                                 | RSAT (Windows feature) |
| Microsoft.Graph.Users                        | Both scripts — Entra user lookup, UsageLocation                                                  | PSGallery              |
| Microsoft.Graph.Groups                       | Both scripts — Entra group membership                                                            | PSGallery              |
| Microsoft.Graph.Identity.DirectoryManagement | Both scripts — group metadata (sync status, type)                                                | PSGallery              |
| Microsoft.Graph.Users.Actions                | New-UserFromAccessProfile only — Set-MgUserLicense, only checked if the profile has any licenses | PSGallery              |

Permissions

- On-prem: rights to read group membership (Export) and create users / modify group membership in the target OU (New-User).

- Microsoft Graph scopes: User.Read.All, Group.Read.All, Directory.Read.All for Export; User.ReadWrite.All, Group.ReadWrite.All, GroupMember.ReadWrite.All, Directory.Read.All for New-User.

9\. Parameters

Export-UserAccessProfile.ps1

|                            |              |                                                                                           |
|----------------------------|--------------|-------------------------------------------------------------------------------------------|
| **Parameter**              | **Required** | **Description**                                                                           |
| -SamAccountName            | Yes          | AD SamAccountName of the template user to export access from.                             |
| -ProfileName               | No           | Friendly name for the profile; used for the output filename. Defaults to -SamAccountName. |
| -ProfilePath               | No           | Folder to write the JSON profile into. Defaults to .\AccessProfiles.                      |
| -AutoInstallMissingModules | No           | Install missing PSGallery modules automatically instead of prompting.                     |

New-UserFromAccessProfile.ps1

|                            |              |                                                                                                                                                 |
|----------------------------|--------------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| **Parameter**              | **Required** | **Description**                                                                                                                                 |
| -ProfilePath               | Yes          | Path to the JSON profile produced by Export-UserAccessProfile.ps1.                                                                      |
| -SamAccountName            | No\*         | Logon name for the new user. \*Required when -CloudOnly is used; otherwise auto-generated from -GivenName/-Surname if omitted.                  |
| -CloudOnly                 | No           | Skip AD account creation and AD group provisioning; finish cloud provisioning for an existing account. Requires -SamAccountName. See section 6. |
| -GivenName / -Surname      | No\*         | New user's first/last name. \*Required unless -CloudOnly is specified.                                                                          |
| -UserPrincipalName         | No           | New user's UPN. Cascades from the profile's template-user domain if omitted (see section 7).                                                    |
| -EmailAddress              | No           | Defaults to -UserPrincipalName if omitted.                                                                                                      |
| -TargetOU                  | No           | OU to create the AD user in. Cascades from the profile if omitted (see section 7).                                                              |
| -UsageLocation             | No           | Two-letter country code required before Graph will assign a license. Cascades from the profile if omitted (see section 7).                      |
| -Department / -Title       | No           | Optional AD attributes to set on the new user.                                                                                                  |
| -InitialPassword           | No           | Temporary password as a SecureString. If omitted, a random 16-character complex password is generated and shown once (see section 11).          |
| -EntraConnectServer        | No           | Hostname of your Entra Connect server, used to trigger the delta sync remotely.                                                                 |
| -SkipEntraSyncWait         | No           | Skip triggering/waiting on a delta sync before the cloud steps run.                                                                             |
| -SyncWaitTimeoutSeconds    | No           | Max seconds to wait for the triggered sync. Defaults to 300.                                                                                    |
| -ReportPath                | No           | Folder for the CSV report. Defaults to .\ProvisioningReports.                                                                                   |
| -AutoInstallMissingModules | No           | Install missing PSGallery modules automatically instead of prompting.                                                                           |
| -WhatIf                    | No           | Preview every change without making it.                                                                                                         |

10\. Running it

First-time setup: open New-UserFromAccessProfile.ps1, find section "0. Configuration" near the top, and set real fallback values if you want them (optional — see section 7). Then, step 1, export a profile from a current, correctly-provisioned team member:

.\Export-UserAccessProfile.ps1 -SamAccountName jdoe -ProfileName "Engineering-NewHire"

Step 2 — preview applying it to a new hire:

.\New-UserFromAccessProfile.ps1 -ProfilePath .\AccessProfiles\Engineering-NewHire.json -GivenName John -Surname Smith -TargetOU "OU=Users,DC=contoso,DC=com" -UserPrincipalName jsmith@contoso.com -EntraConnectServer AADC01 -WhatIf

Step 3 — run it for real (drop -WhatIf). No -SamAccountName given, so it generates "JSmith" (or "JSmith2" etc. if taken). If the profile already has SourceUserOU/SourceUser/UsageLocation set, -TargetOU and -UserPrincipalName above can usually be dropped entirely:

.\New-UserFromAccessProfile.ps1 -ProfilePath .\AccessProfiles\Engineering-NewHire.json -GivenName John -Surname Smith -EntraConnectServer AADC01

If the cloud steps fail because Entra Connect hadn't synced the new account yet, finish the job once sync has caught up:

.\New-UserFromAccessProfile.ps1 -ProfilePath .\AccessProfiles\Engineering-NewHire.json -SamAccountName JSmith -CloudOnly

The command-line prompt matters here: if you launch the script with a required parameter omitted, PowerShell will interactively prompt for it and take whatever you type completely literally — including any quote characters you type at that prompt. Always pass -ProfilePath (and any path containing spaces) as a normal quoted argument on the command line rather than typing it in response to an interactive prompt.

11\. Reading the output and handling the temporary password

Each run produces a timestamped CSV in -ReportPath (one row per action: stage, item, action, status, detail), plus a console summary table. Status values are Success, Skipped, Failed, or TimedOut — Skipped rows under -CloudOnly are expected (AD/AD-Groups steps intentionally not run), everything else worth a Failed/TimedOut is worth a manual look.

SECURITY NOTE ON THE TEMPORARY PASSWORD: unlike the offboarding and audit scripts, this script deliberately does not call Start-Transcript. If a password is auto-generated, it is displayed once in the console and is never written to the CSV report or any log file — copy it immediately to whatever secure channel you use to hand credentials to a new hire. The account is created with -ChangePasswordAtLogon, so this password is only ever meant to be used once.

12\. Known limitations / things to watch

- The exported profile is a literal snapshot of the template user's access at export time — it can include personal exceptions that aren't really part of the role. Review the JSON (or the template user's own access) before applying it broadly, and re-export periodically as the template user's role-appropriate access changes.

- There's no check that a license SKU actually has seats available — if a SKU is out of licenses, that one Set-MgUserLicense call fails and is logged, but the others in the profile still proceed.

- Dynamic membership groups recorded in the profile are informational only — the new user joins automatically if they happen to match the group's own rule (e.g. an "All Users" style group), never because this script added them.

- -WhatIf previews the AD-side steps meaningfully, but the cloud-side steps (Graph group membership, license assignment) can only be meaningfully previewed once the new Entra ID user object actually exists — under -WhatIf with no real AD account created, those steps have nothing to look up yet.

- This script does not create a mailbox directly — if any assigned license includes Exchange Online, Exchange auto-provisions the mailbox once the license takes effect and the next processing cycle completes, typically within a few minutes.

- If -EntraConnectServer is omitted, the script still runs correctly, it just won't trigger a sync itself — the cloud steps may need a re-run (with -CloudOnly) once your regular sync schedule catches up.

- Keep the tenant-preset and neutral script variants in sync if you customize the shared logic — the only lines that should differ are the section-0 defaults.

13\. Security notes

- Prefer a dedicated provisioning service account with the minimum delegated AD rights and a certificate-based Graph app registration over an individual admin's interactive credentials for any scheduled/unattended use.

- Never hard-code credentials, client secrets, or tokens in either script.

- Treat exported access-profile JSON files as sensitive-ish: they're an inventory of exactly which groups and licenses a real employee has. Store them somewhere access-controlled, same as the CSV reports.

- Review the -WhatIf output before the first live run against any new OU or template profile.
