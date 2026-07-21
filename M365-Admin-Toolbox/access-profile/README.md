# access-profile

Profile-driven new-hire provisioning and hybrid offboarding: capture a template user's
access as a portable JSON "access profile," apply that profile to provision a new hire,
and audit/offboard hybrid (on-prem AD + Entra ID) accounts. Unlike most of the rest of
this toolbox, these four scripts are self-contained standalone scripts rather than
functions built on `core\Connect-M365.ps1` / `config\tenants.json` - each connects
directly to Exchange Online / Microsoft Graph / on-prem AD itself, checks for its own
required modules, and writes its own transcript/CSV report. That's a deliberate,
different design for this script family (it started life as a portable standalone
package), not an oversight - don't refactor these to the tenant-config connection
pattern used elsewhere in this toolbox.

There is no pre-existing `docs\README-*.md` for this folder - this README was written
directly from the script source. See `docs\Hybrid-NewHire-Provisioning-Runbook.docx/.pdf`,
`docs\Hybrid-Offboarding-Runbook.docx/.pdf`, and
`docs\Script-Configuration-and-Flags-Reference.docx/.pdf` for the fuller narrative
runbooks these scripts were originally documented with.

**A tenant-preset copy of every script here** (identical logic, Section 0 fallback
constants preset to your tenant's real values instead of `CHANGE-ME` placeholders) lives
in `TenantPreset\M365-Admin-Toolbox\access-profile\` in the tenant-preset copy of this
toolkit. The folder location (this neutral template vs. your private tenant-preset copy) is what
distinguishes the two variants - no script here has a tenant name in its filename.

---

## The profile-driven design

Instead of hardcoding which AD groups, Entra groups, and licenses a new hire needs,
`Export-UserAccessProfile.ps1` reads all of that off an existing "template" user (e.g. a
current Engineering team member with exactly the access a new Engineering hire should
get) and writes it to a portable JSON file - the "access profile." `New-UserFromAccessProfile.ps1`
then reads that JSON and applies the same groups/licenses/OU/UPN-domain/usage-location to
a brand-new AD user.

This means onboarding a new hire into an existing role doesn't require anyone to remember
or re-type the specific groups and licenses that role needs - clone them from whoever
currently has the role, review the JSON file once, and apply it.

A typical access profile JSON looks like:

```json
{
  "ProfileName": "Engineering-NewHire",
  "SourceUser": "jdoe@contoso.com",
  "SourceUserOU": "OU=Engineering,OU=Users,DC=contoso,DC=com",
  "UsageLocation": "US",
  "ExportedDate": "2026-07-01 09:15:00",
  "ADGroups": [
    { "Name": "Engineering-VPN", "DistinguishedName": "CN=Engineering-VPN,OU=Groups,DC=contoso,DC=com" }
  ],
  "EntraGroups": [
    { "GroupId": "...", "GroupName": "Engineering Team", "IsSynced": true, "IsDynamic": false, "IsMailEnabled": false, "IsM365Group": true }
  ],
  "Licenses": [
    { "SkuId": "...", "SkuPartNumber": "SPE_E3" }
  ]
}
```

`New-UserFromAccessProfile.ps1` uses `SourceUserOU`, the domain portion of `SourceUser`,
and `UsageLocation` as its defaults for the new hire's OU / UPN suffix / usage location,
so a typical run needs almost nothing else besides `-GivenName`/`-Surname`. Section
"0. Configuration" in each script only holds **last-resort fallback constants** - used
only if you pass a param explicitly and the profile is missing that data (e.g. an older
profile). In this neutral template those fallbacks are all literal `CHANGE-ME`
placeholders; in your private tenant-preset copy they're preset to your tenant's real values (except
the new-hire OU, which is still `OU=CHANGE-ME-NewUsers,...` because the real OU wasn't
confirmed when this was built - leave that placeholder as-is until it's confirmed).

---

## Prerequisites

- PowerShell 5.1+ (each script starts with `#Requires -Version 5.1`).
- `ActiveDirectory` RSAT module, installed on the machine running these scripts (not
  auto-installable from PSGallery - each script tells you exactly how to get it if it's
  missing).
- Microsoft Graph PowerShell SDK modules: `Microsoft.Graph.Users`, `Microsoft.Graph.Groups`,
  `Microsoft.Graph.Identity.DirectoryManagement`, and (for license assignment/removal)
  `Microsoft.Graph.Users.Actions`. Pass `-AutoInstallMissingModules` to install missing
  PSGallery modules automatically instead of being prompted.
- `ExchangeOnlineManagement` module (only needed by `Offboard-HybridUser.ps1`, for the
  shared-mailbox conversion step).
- Delegated or app-only Graph scopes: `User.Read.All`/`User.ReadWrite.All`,
  `Group.Read.All`/`Group.ReadWrite.All`, `GroupMember.ReadWrite.All`,
  `Directory.Read.All` (exact set varies per script - see each script's `.NOTES`).
- For hybrid sync features (`-EntraConnectServer`): PowerShell remoting rights to the
  Entra Connect / AD Connect server.
- Each script manages its own connections (`Connect-MgGraph`, `Connect-ExchangeOnline`) -
  there's no dependency on `core\Connect-M365.ps1` or `config\tenants.json` here.

---

## Scripts

### Export-UserAccessProfile.ps1

Reads a template AD user's local AD group memberships, Entra ID group memberships
(tagged synced / cloud-only / dynamic), assigned Entra ID licenses, own OU, and Entra
usage location, and writes it all to a JSON access profile. Read-only - never modifies
the template user.

**Parameters**
| Parameter | Notes |
|---|---|
| `SamAccountName` | Mandatory. On-prem AD SamAccountName of the template user. |
| `ProfileName` | Friendly name for the profile; defaults to `SamAccountName`. |
| `ProfilePath` | Output folder. Default `.\AccessProfiles`. |
| `AutoInstallMissingModules` | Auto-install missing PSGallery modules instead of prompting. |

**Example**
```powershell
.\Export-UserAccessProfile.ps1 -SamAccountName jdoe -ProfileName "Engineering-NewHire"
```

---

### New-UserFromAccessProfile.ps1

Creates a new on-prem AD user and provisions them with the AD groups, Entra groups, and
licenses captured in an access profile JSON. Supports `-CloudOnly` to resume cloud-side
provisioning (sync wait, usage location, cloud groups, licenses) after an AD account was
already created in a prior run. Supports `-WhatIf`.

**Parameters**
| Parameter | Notes |
|---|---|
| `ProfilePath` | Mandatory. Path to the JSON access profile (from `Export-UserAccessProfile.ps1`). |
| `SamAccountName` | Optional - auto-generated from `-GivenName`/`-Surname` (first-initial + surname) if omitted. |
| `CloudOnly` | Skip AD creation/group provisioning; finish cloud steps for an existing AD account. |
| `GivenName` / `Surname` | Required unless `-CloudOnly`. |
| `UserPrincipalName` / `EmailAddress` / `TargetOU` / `UsageLocation` | Optional overrides - default to the profile's own values, then Section 0 fallback constants. |
| `Department` / `Title` | Optional AD attributes. |
| `InitialPassword` | Optional `SecureString`; auto-generated and shown once if omitted. |
| `EntraConnectServer` / `SkipEntraSyncWait` / `SyncWaitTimeoutSeconds` | Entra Connect delta sync controls. |
| `ReportPath` | Default `.\ProvisioningReports`. |
| `AutoInstallMissingModules` | Auto-install missing PSGallery modules. |

**Configuration block (Section 0):** `$Script:DefaultNewUserOU`, `$Script:DefaultUpnSuffix`,
`$Script:DefaultUsageLocation` - last-resort fallbacks only, used when a param is omitted
*and* the profile has no value for it.

**Example**
```powershell
.\New-UserFromAccessProfile.ps1 -ProfilePath .\AccessProfiles\Engineering-NewHire.json `
    -GivenName John -Surname Smith -TargetOU "OU=Users,DC=contoso,DC=com" `
    -UserPrincipalName jsmith@contoso.com -EntraConnectServer AADC01
```

**Known gotcha:** this script deliberately does **not** call `Start-Transcript` - an
auto-generated temporary password is shown once in the console and never written to any
log or report file.

---

### Audit-SharedMailboxOU.ps1

Audits every AD account already sitting in the shared-mailbox/disabled-users OU and
flags anything `Offboard-HybridUser.ps1` should have cleaned up but didn't (AD still
enabled, leftover AD/Entra group memberships, mailbox not converted to shared, Entra
sign-in not blocked). Read-only by default; pass `-Remediate` (with `-WhatIf` support)
to fix what it finds using the same removal logic as the offboarding script.

**Parameters**
| Parameter | Notes |
|---|---|
| `SharedMailboxOU` | Distinguished name of the OU to audit. No real default in the neutral template - pass it or edit Section 0. |
| `ReportPath` | Default `.\AuditReports`. |
| `Remediate` | Fix what's found instead of only reporting. Supports `-WhatIf`. |
| `AutoInstallMissingModules` | Auto-install missing PSGallery modules. |

**Example**
```powershell
.\Audit-SharedMailboxOU.ps1 -SharedMailboxOU "OU=Shared Mailboxes,DC=contoso,DC=com" -Remediate -WhatIf
```

---

### Offboard-HybridUser.ps1

Full hybrid offboarding: disables the AD account, moves it to the shared-mailbox OU,
converts the mailbox to shared, removes all Entra ID licenses, strips every AD and Entra
group membership (auto-detecting synced vs. cloud-only groups and routing removal to the
correct system), triggers/waits for an Entra Connect delta sync, and revokes active cloud
sessions. Supports `-CloudOnly` to retry just the cloud-side steps, and `-WhatIf`.

**Parameters**
| Parameter | Notes |
|---|---|
| `SamAccountName` | Mandatory. |
| `CloudOnly` | Skip AD-side steps; retry only mailbox conversion, license removal, cloud group cleanup, session revoke. |
| `SharedMailboxOU` | Target OU for the disabled account. No real default in the neutral template. |
| `SkipMailboxConversion` / `SkipLicenseRemoval` | Opt-out switches. |
| `SkipEntraSyncWait` / `EntraConnectServer` / `SyncWaitTimeoutSeconds` | Sync controls. |
| `SkipSyncRecheck` / `SyncRecheckWaitSeconds` | Second-pass re-check of synced groups after the sync wait. |
| `ReportPath` | Default `.\OffboardingReports`. |
| `AutoInstallMissingModules` | Auto-install missing PSGallery modules. |

**Configuration block (Section 0):** `$Script:DefaultSharedMailboxOU` (last-resort
fallback only) and `$Script:ScriptVersion` (bumped per behavior change, logged in every
report so a saved CSV alone tells you which script version produced it).

**Example**
```powershell
.\Offboard-HybridUser.ps1 -SamAccountName jsmith -SharedMailboxOU "OU=Shared Mailboxes,DC=contoso,DC=com" -EntraConnectServer AADC01
```

---

## Known gotchas

- All four scripts throw early with clear instructions if a Section 0 fallback constant
  is still a `CHANGE-ME` placeholder and no override was supplied - check the script's
  own error message first before editing anything.
- `Offboard-HybridUser.ps1` and `Audit-SharedMailboxOU.ps1` share the same synced-vs-
  cloud-only group detection logic; a change to one group-handling behavior should
  generally be mirrored in the other.
- These scripts are standalone (no dependency on `core\Connect-M365.ps1` /
  `config\tenants.json`) by design - see the note at the top of this README before
  "fixing" that.
