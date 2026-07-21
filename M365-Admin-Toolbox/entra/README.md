# entra

Microsoft Entra ID (Azure AD) reporting and group-membership management scripts. These
cover day-to-day directory administration: managing a user's group memberships, and
exporting inventories of Conditional Access policies, license (SKU) consumption, and
PIM role assignments/eligibilities.

All scripts are tenant-neutral: they take a mandatory `-TenantName` parameter, dot-source
`..\core\Common.ps1`, `..\core\Retry.ps1`, and `..\core\ErrorHandling.ps1`, and connect via
`..\core\Connect-M365.ps1`, which resolves tenant details (tenant ID, domain, app
registration) from `config\tenants.json`. No script hardcodes a tenant ID, domain, or UPN.

---

## Prerequisites

- PowerShell 7+ recommended (Windows PowerShell 5.1 also supported).
- Microsoft Graph PowerShell SDK module (`Microsoft.Graph.Authentication` at minimum;
  the toolbox auto-installs missing modules via `Ensure-ModuleInstalled` if
  `ModuleAutoInstall` is enabled in `config\tenants.json`).
- A tenant entry in `config\tenants.json` for every `-TenantName` you pass in.
- Delegated or app-only Graph permissions appropriate to each script (see below). The
  default delegated scope set requested by `Connect-M365.ps1` includes
  `User.Read.All`, `Directory.ReadWrite.All`, `Group.ReadWrite.All`, `AuditLog.Read.All`,
  `Device.ReadWrite.All`, `Organization.Read.All`, `Mail.ReadWrite`, and
  `Mail.ReadWrite.Shared`. `Report-PIMRoleAssignments.ps1` additionally requests
  `RoleManagement.Read.Directory` and `Directory.Read.All`.

---

## Scripts

### Entra-UserGroupMgmt.ps1

Adds, removes, or lists a single Entra ID user's group memberships. Looks up the user by
UPN via `Get-MgUser`, then performs one of `New-MgGroupMember`,
`Remove-MgGroupMemberByRef`, or `Get-MgUserMemberOf` depending on `-Action`. All Graph
calls are wrapped in `Invoke-WithRetry` for throttle safety and the whole operation in
`Invoke-ToolboxSafely` for consistent error logging.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. Tenant key from `config\tenants.json`. |
| `Action` | Mandatory. One of `AddUserToGroup`, `RemoveUserFromGroup`, `ListUserGroups`. |
| `UserPrincipalName` | Mandatory. UPN of the target user. |
| `GroupId` | Object ID (GUID) of the target group. Required for Add/Remove, ignored for List. |

**Configuration block:** `$MaxRetryAttempts` (5), `$RetryBaseDelaySeconds` (5).

**Example**
```powershell
.\Entra-UserGroupMgmt.ps1 -TenantName 'Tenant-Example-NA' -Action AddUserToGroup `
    -UserPrincipalName 'jdoe@contoso.com' -GroupId '11111111-2222-3333-4444-555555555555'

.\Entra-UserGroupMgmt.ps1 -TenantName 'Tenant-Example-NA' -Action ListUserGroups `
    -UserPrincipalName 'jdoe@contoso.com'
```

**Required Graph permissions:** `User.Read.All`, `Group.ReadWrite.All` (read-only for
`ListUserGroups`).

---

### Report-ConditionalAccessPolicies.ps1

Exports a CSV inventory of all Conditional Access policies (name, state, created/modified
timestamps) via `Get-MgIdentityConditionalAccessPolicy -All`.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `OutputCsv` | Output path. Defaults to `.\reports\ConditionalAccessPolicies.csv`. |

**Configuration block:** `$MaxRetryAttempts` (5), `$RetryBaseDelaySeconds` (5).

**Example**
```powershell
.\Report-ConditionalAccessPolicies.ps1 -TenantName 'Tenant-Example-NA' -OutputCsv 'C:\Reports\CA-Policies.csv'
```

**Required Graph permissions:** `Policy.Read.All` (or equivalent Conditional Access read scope).

---

### Report-LicenseInventory.ps1

Builds a license inventory from subscribed SKUs (`Get-MgSubscribedSku`) with consumed,
prepaid, and available unit counts. Optionally appends service plan detail per SKU
(`-IncludeServicePlans`) and one row per user license assignment (`-IncludeUserAssignments`).

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `OutputCsv` | Output path. Defaults to `.\reports\LicenseInventory.csv`. |
| `IncludeServicePlans` | Adds a semicolon-delimited service plan list per SKU row. |
| `IncludeUserAssignments` | Also enumerates all users and adds one row per assigned license. |

**Configuration block:** `$MaxRetryAttempts` (5), `$RetryBaseDelaySeconds` (5),
`$UserAssignmentProperties` (Graph properties requested when enumerating users).

**Example**
```powershell
.\Report-LicenseInventory.ps1 -TenantName 'Tenant-Example-NA' -IncludeServicePlans -IncludeUserAssignments -OutputCsv 'C:\Reports\Licenses.csv'
```

**Required Graph permissions:** `Organization.Read.All`, `User.Read.All` (only needed when
`-IncludeUserAssignments` is used).

---

### Report-PIMRoleAssignments.ps1

Exports both active and eligible PIM directory role assignments
(`Get-MgRoleManagementDirectoryRoleAssignmentScheduleInstance` and
`Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance`), resolving each assignment
to a friendly role name via `Get-MgRoleManagementDirectoryRoleDefinition` (which, unlike
`Get-MgDirectoryRole`, includes roles that have never been activated in the tenant).

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `OutputCsv` | Output path. Defaults to `.\reports\PIMRoleAssignments.csv`. |

**Configuration block:** `$MaxRetryAttempts` (5), `$RetryBaseDelaySeconds` (5),
`$RequiredGraphScopes` (`RoleManagement.Read.Directory`, `Directory.Read.All`).

**Example**
```powershell
.\Report-PIMRoleAssignments.ps1 -TenantName 'Tenant-Example-NA' -OutputCsv 'C:\Reports\PIM-Roles.csv'
```

**Required Graph permissions:** `RoleManagement.Read.Directory`, `Directory.Read.All`.

---

### Report-DynamicGroupInactiveFilter.ps1

Audits every dynamic-membership group and flags **user-scoped** rules that don't
exclude disabled/inactive accounts (no `accountEnabled` clause). Device-scoped
rules (`device.*` attributes — Autopilot/Intune enrollment groups) are reported
separately and never flagged, since the accountEnabled-exclusion concept doesn't
apply to device objects the same way. Read-only by default; `-Fix` interactively
patches flagged groups one at a time with confirmation before any change is made.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `OutputCsv` | Output path. Defaults to `.\reports\DynamicGroupInactiveFilter.csv`. |
| `Fix` | Interactively appends `(user.accountEnabled -eq true)` to flagged user-scoped rules via `Update-MgGroup`, confirmed per group. Off by default. |

**Configuration block:** `$MaxRetryAttempts` (5), `$RetryBaseDelaySeconds` (5).

**Example**
```powershell
.\Report-DynamicGroupInactiveFilter.ps1 -TenantName 'Tenant-Example-NA'
.\Report-DynamicGroupInactiveFilter.ps1 -TenantName 'Tenant-Example-NA' -Fix
```

**Required Graph permissions:** `Group.Read.All` (report only), `Group.ReadWrite.All` (`-Fix`).

**When to run it:** after creating any new dynamic user group, and periodically
(e.g. quarterly) as a hygiene check alongside license/seat reviews.

---

### Audit-LicenseWaste.ps1

Standalone, self-contained script (not built on `core\Connect-M365.ps1` /
`config\tenants.json` — it manages its own `Connect-MgGraph` connection and module
checks). Finds Entra ID licenses being paid for but not delivering value: assigned to
disabled accounts (the most common finding — usually a sign
`access-profile\Offboard-HybridUser.ps1`'s license-removal step didn't run), assigned to
accounts with no sign-in within `-InactiveDays`, or sitting unused against the purchased
seat count per SKU. Also prints a per-SKU purchased/assigned/available summary. Read-only.

**Parameters**
| Parameter | Notes |
|---|---|
| `InactiveDays` | Soft-waste staleness threshold in days. Default `90`. Disabled accounts are always flagged regardless. |
| `ReportPath` | Folder for the CSV report and transcript log. Default `.\AuditReports`. |
| `AutoInstallMissingModules` | Auto-install missing PSGallery modules instead of prompting. |

**Required modules:** `Microsoft.Graph.Users`, `Microsoft.Graph.Identity.DirectoryManagement`.
**Required Graph scopes:** `User.Read.All`, `AuditLog.Read.All`, `Organization.Read.All`
(the SKU summary section is skipped and noted as unavailable without `Organization.Read.All`).

**Example**
```powershell
.\Audit-LicenseWaste.ps1
.\Audit-LicenseWaste.ps1 -InactiveDays 30
```

---

### Audit-StaleAccounts.ps1

Standalone, self-contained script (not built on `core\Connect-M365.ps1` /
`config\tenants.json` — it manages its own `Connect-MgGraph` connection and module
checks). Flags enabled AD accounts that haven't actually been used, on-prem or in the
cloud, for longer than `-InactiveDays`. Compares AD's `LastLogonTimestamp` against
Entra's `signInActivity.lastSignInDateTime` and takes whichever is more recent as "last
known activity," to avoid false positives for hybrid users active mostly in one system.
Read-only — never disables anything. Once you've reviewed the flagged list, run
`access-profile\Offboard-HybridUser.ps1` against genuinely stale accounts.

**Parameters**
| Parameter | Notes |
|---|---|
| `InactiveDays` | Staleness threshold in days. Default `90`. |
| `SearchBase` | Optional AD OU to limit the scan to. Omit to scan the whole domain. |
| `ExcludeOU` | One or more OU distinguished names to skip (e.g. an already-offboarded/shared-mailbox OU). |
| `ReportPath` | Folder for the CSV report and transcript log. Default `.\AuditReports`. |
| `AutoInstallMissingModules` | Auto-install missing PSGallery modules instead of prompting. |

**Required modules:** `ActiveDirectory` (RSAT), `Microsoft.Graph.Users`.
**Required Graph scopes:** `User.Read.All`, `AuditLog.Read.All`.

**Example**
```powershell
.\Audit-StaleAccounts.ps1
.\Audit-StaleAccounts.ps1 -InactiveDays 60 -ExcludeOU "OU=Shared Mailboxes,DC=contoso,DC=com"
```

---

## Related

- `azure\Azure-SubscriptionContext.ps1` — connects to Azure and sets subscription context
  for follow-on operations (separate from Entra ID directory management above).
- `runbooks\` — contains an Azure Automation style orchestration example for running these
  reports unattended.
- `docs\README-Entra-Azure.md` — original short-form reference doc for this folder plus
  the `azure\` scripts.
