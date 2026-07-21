# bulk

CSV-driven multi-tenant orchestration — each script loops over rows in an input CSV (one row per tenant, or per user for the lifecycle scripts) and calls a corresponding single-tenant operational script elsewhere in the toolbox.

## Common reliability pattern

All 12 scripts in this folder follow the same shape, confirmed from the current source of every script:
- Each CSV row is processed inside its own `try/catch`, so one bad row (bad tenant name, auth failure, network blip, bad UPN, etc.) does not abort the rest of the run.
- Every script writes a **summary CSV** to `..\reports` at the end of the run (timestamped, e.g. `BulkAutopilotReportSummary_20260702101500.csv`) with at least `Status` (`Success`/`Failed`) and `Error` columns per row, and the path to that summary CSV is the script's final pipeline output. This is a recent reliability fix layered on top of the original per-tenant report generation, so a failed row is always visible and retryable without re-running the whole batch.
- The 10 tenant-report scripts (all except the two user lifecycle scripts) also write a **per-tenant report CSV** in addition to the summary CSV — the per-tenant file is the actual report data (e.g. mailbox list, device list), while the summary CSV just records whether that per-tenant report succeeded and where it landed (`ReportPath` column).
- The two user lifecycle scripts (`Invoke-BulkUserOnboarding.ps1`, `Invoke-BulkUserOffboarding.ps1`) don't produce a separate per-tenant report file — instead their single summary CSV records one row per **user**, not per tenant, with `TenantName`, `UserPrincipalName`, `Status`, and `Error` (plus `TemporaryPassword` for onboarding).

## Prerequisites

Requirements vary per script depending on which single-tenant operational script it invokes — see the table below for the mapping. In general, expect some combination of:
- Microsoft Graph modules (`Microsoft.Graph.Authentication` etc.) for anything touching Entra ID, Intune, PIM, Conditional Access, or license data.
- `ExchangeOnlineManagement` for mailbox/transport rule/forwarding scripts.
- `MicrosoftTeams` for the Teams inventory script.
- `Microsoft.Online.SharePoint.PowerShell` for the SharePoint sites script.
- On-prem AD tooling (e.g. `ActiveDirectory` module, WinRM/PS-Remoting to a domain controller) for the hybrid branches of the onboarding/offboarding scripts.

All connection/module bootstrapping is handled by `core\Connect-M365.ps1`, which the underlying operational scripts dot-source — the bulk scripts themselves do not connect to anything directly (see `..\core\README.md` and `..\docs\README-Core.md`). Every script also requires a valid `-CsvPath` pointing at a CSV with, at minimum, a `TenantName` column (see `..\config\tenants.json` for valid tenant names in your environment).

**`UserPrincipalName` column shorthand:** in `Invoke-BulkUserOnboarding.ps1`'s CSV, this column can be a full address (`jdoe@contoso.com`) or just the local part (`jdoe`) — `New-UserLifecycle.ps1` and `New-HybridADUser.ps1` both auto-append the tenant's `PrimaryDomain` when no `@` is present (see `Resolve-ToolboxUserPrincipalName` in `..\core\README.md`). This removes a common source of bad rows: someone typing the wrong or a typo'd domain into the CSV. **`UsageLocation` column** can also be left blank per row — it falls back to the tenant's `Cloud.DefaultUsageLocation` automatically.

## Script reference

| Script | Required/optional CSV columns | Calls (operational script) | Key switches/params |
|---|---|---|---|
| `Invoke-BulkAutopilotReport.ps1` | `TenantName` (required) | `..\intune\Report-AutopilotDevices.ps1` | none beyond `-CsvPath` |
| `Invoke-BulkComplianceAuditExport.ps1` | `TenantName` (required) | `..\security\Export-ComplianceAuditData.ps1` | `-StartDate` / `-EndDate` (mandatory, applied to every tenant), `-RecordType` (default `ExchangeAdmin`) |
| `Invoke-BulkConditionalAccessReport.ps1` | `TenantName` (required) | `..\entra\Report-ConditionalAccessPolicies.ps1` | none beyond `-CsvPath` |
| `Invoke-BulkLicenseInventory.ps1` | `TenantName` (required) | `..\entra\Report-LicenseInventory.ps1` | `-IncludeServicePlans`, `-IncludeUserAssignments` (both applied to every tenant) |
| `Invoke-BulkMailboxAudit.ps1` | `TenantName` (required), `MailboxFilter` (optional per-row, defaults to `*`) | `..\exchange\Audit-Mailboxes.ps1` | `-SharedOnly` (applied to every tenant) |
| `Invoke-BulkMailboxForwardingReport.ps1` | `TenantName` (required) | `..\exchange\Report-MailboxForwarding.ps1` | `-IncludeInboxRules` (applied to every tenant) |
| `Invoke-BulkPIMRoleReport.ps1` | `TenantName` (required) | `..\entra\Report-PIMRoleAssignments.ps1` | none beyond `-CsvPath` |
| `Invoke-BulkSharedMailboxAudit.ps1` | `TenantName` (required) | `..\exchange\Report-SharedMailboxPermissions.ps1` | `-IncludeSendAs` (applied to every tenant) |
| `Invoke-BulkSharePointSites.ps1` | `TenantName` (required) | `..\sharepoint\Report-SharePointSites.ps1` | none beyond `-CsvPath` |
| `Invoke-BulkStaleDeviceReport.ps1` | `TenantName` (required) | `..\intune\Report-StaleDevices.ps1` | `-InactiveDays` (default `30`, applied to every tenant) |
| `Invoke-BulkTeamsInventory.ps1` | `TenantName` (required) | `..\teams\Report-TeamsInventory.ps1` | `-IncludeOwners`, `-IncludeMembers` (both applied to every tenant) |
| `Invoke-BulkTransportRuleReport.ps1` | `TenantName` (required) | `..\exchange\Report-TransportRules.ps1` | none beyond `-CsvPath` |
| `Invoke-BulkUserOffboarding.ps1` | `TenantName`, `HybridDisableOnPrem`, `SamAccountName`, `UserPrincipalName`, `ConvertMailboxToShared`, `RemoveLicenses`, `DisableDevices`, `RevokeSessions`, `MoveOnPremObjectToDisabledOU`, `RemoveFromAllNonDefaultGroups` (see `templates\BulkUserOffboarding.csv`) | `..\lifecycle\Disable-UserLifecycle.ps1`; conditionally `..\hybrid\Disable-HybridADUser.ps1` + `..\hybrid\Start-ADSync.ps1` | No script-level switch; per-row `HybridDisableOnPrem = 'true'` (plus a `SamAccountName` value) is what gates the hybrid on-prem branch |
| `Invoke-BulkUserOnboarding.ps1` | `TenantName`, `HybridCreateOnPremFirst`, `SamAccountName`, `UserPrincipalName`, `DisplayName`, `GivenName`, `Surname`, `MailNickname`, `Department`, `JobTitle`, `OfficeLocation`, `UsageLocation`, `InitialPassword`, `LicenseSkuPartNumbers`, `GroupIds`, `OnPremGroups` (see `templates\BulkUserOnboarding.csv`; `LicenseSkuPartNumbers`/`GroupIds`/`OnPremGroups` are semicolon-delimited) | `..\lifecycle\New-UserLifecycle.ps1`; conditionally `..\hybrid\New-HybridADUser.ps1` + `..\hybrid\Start-ADSync.ps1` | `-HybridCreateOnPremFirst` (script-level global opt-in switch) |

---

## Invoke-BulkAutopilotReport.ps1

### What it does
CSV-driven bulk orchestrator. Reads a CSV of tenant rows and, for each row, calls `..\intune\Report-AutopilotDevices.ps1` to produce a per-tenant Autopilot devices report. Each row runs in its own try/catch; a per-tenant report CSV is written for successful rows, and a single `BulkAutopilotReportSummary_<timestamp>.csv` recording `TenantName`/`ReportPath`/`Status`/`Error` is written at the end.

### Parameters
| Parameter | Notes |
|---|---|
| `CsvPath` | Mandatory. Path to the input CSV. Must contain a `TenantName` column. |

### Prerequisites
- Microsoft Graph modules (Intune/Autopilot device data is read via Graph) — installed/connected through `..\intune\Report-AutopilotDevices.ps1` → `core\Connect-M365.ps1 -ConnectIntune`.

### Usage
```powershell
.\Invoke-BulkAutopilotReport.ps1 -CsvPath 'C:\Reports\tenants.csv'
```

---

## Invoke-BulkTeamsInventory.ps1

### What it does
CSV-driven bulk orchestrator for Teams inventory reporting. For each tenant row, calls `..\teams\Report-TeamsInventory.ps1` with `-TenantName` and `-OutputCsv`, plus `-IncludeOwners`/`-IncludeMembers` when those script-level switches are passed. Per-tenant reports and a `BulkTeamsInventorySummary_<timestamp>.csv` are written to `..\reports`.

### Parameters
| Parameter | Notes |
|---|---|
| `CsvPath` | Mandatory. Path to the input CSV. Must contain a `TenantName` column. |
| `IncludeOwners` | Applied to every tenant in the run; passed through to `Report-TeamsInventory.ps1` to include team owners. |
| `IncludeMembers` | Applied to every tenant in the run; passed through to `Report-TeamsInventory.ps1` to include team members. |

### Prerequisites
- `MicrosoftTeams` module — installed/connected through `..\teams\Report-TeamsInventory.ps1` → `core\Connect-M365.ps1 -ConnectTeams`.

### Usage
```powershell
# Basic inventory, no owners/members detail
.\Invoke-BulkTeamsInventory.ps1 -CsvPath 'C:\Reports\tenants.csv'

# Full inventory including owners and members for every tenant in the CSV
.\Invoke-BulkTeamsInventory.ps1 -CsvPath 'C:\Reports\tenants.csv' -IncludeOwners -IncludeMembers
```

---

## Invoke-BulkUserOnboarding.ps1

### What it does
Reads a CSV of individual users (not tenants-only — one row per new hire) and, for each row, invokes `..\lifecycle\New-UserLifecycle.ps1` to create/configure the cloud account (license SKUs, group membership, etc.). If **both** the script-level `-HybridCreateOnPremFirst` switch is passed **and** that row's `HybridCreateOnPremFirst` CSV value is `'true'`, it first invokes `..\hybrid\New-HybridADUser.ps1` to create the on-prem AD object, then `..\hybrid\Start-ADSync.ps1 -PolicyType Delta` to sync it to the cloud, before creating/updating the cloud account. This dual-gate (script switch AND per-row CSV flag) is intentional — an explicit global opt-in plus an explicit per-row opt-in — so hybrid on-prem account creation never happens by accident on a mixed cloud-only/hybrid tenant list.

Each row is processed independently in its own try/catch. A per-row summary (`TenantName`, `UserPrincipalName`, `Status`, `TemporaryPassword`, `Error`) is written to a timestamped `BulkUserOnboarding_<timestamp>.csv` in `..\reports`.

Expected CSV columns (see `templates\BulkUserOnboarding.csv`): `TenantName`, `HybridCreateOnPremFirst`, `SamAccountName`, `UserPrincipalName`, `DisplayName`, `GivenName`, `Surname`, `MailNickname`, `Department`, `JobTitle`, `OfficeLocation`, `UsageLocation`, `InitialPassword`, `LicenseSkuPartNumbers`, `GroupIds`, `OnPremGroups` — the last three are semicolon-delimited lists (e.g. `ENTERPRISEPACK;SPE_E5`).

### Parameters
| Parameter | Notes |
|---|---|
| `CsvPath` | Mandatory. Path to the input CSV — see `templates\BulkUserOnboarding.csv` for the expected format and example rows. |
| `HybridCreateOnPremFirst` | Global opt-in switch. Must be passed together with a per-row `HybridCreateOnPremFirst = 'true'` CSV value for the on-prem AD creation branch to run for that row. |

### Prerequisites
- Microsoft Graph modules for the cloud account creation path (`..\lifecycle\New-UserLifecycle.ps1`).
- On-prem AD tooling (e.g. `ActiveDirectory` module / remoting access to a domain controller) plus a working AD Connect / Entra Connect sync setup, only if using `-HybridCreateOnPremFirst` against hybrid tenant rows.

### Usage
```powershell
# Cloud-only onboarding, no on-prem AD creation regardless of CSV content
# (the per-row HybridCreateOnPremFirst='true' flags are ignored without the switch)
.\Invoke-BulkUserOnboarding.ps1 -CsvPath 'D:\ADMIN SCRIPTS\M365-Admin-Toolbox-v6.2\M365-Admin-Toolbox\templates\BulkUserOnboarding.csv'

# Full run: creates on-prem AD accounts first for any row where
# HybridCreateOnPremFirst = 'true' (e.g. the Tenant-Example-NA hybrid tenant),
# then creates/configures the cloud account for every row.
.\Invoke-BulkUserOnboarding.ps1 -CsvPath 'D:\ADMIN SCRIPTS\M365-Admin-Toolbox-v6.2\M365-Admin-Toolbox\templates\BulkUserOnboarding.csv' -HybridCreateOnPremFirst
```

### Known gotchas
- The script has a `TODO` comment directly above its param block flagging a security concern:
  > `TODO: TemporaryPassword is written to this CSV in plaintext. Consider redacting it from the summary CSV and instead delivering passwords via a secure channel (e.g. Secrets.ps1 / SecretManagement) for production use.`

  In its current form, `BulkUserOnboarding_<timestamp>.csv` in `..\reports` contains each new user's `TemporaryPassword` in cleartext. Treat that summary CSV as sensitive — restrict access to `..\reports`, delete/rotate it promptly after distributing credentials, and consider routing passwords through `core\Secrets.ps1` instead for anything beyond ad-hoc/test use.
- `LicenseSkuPartNumbers`, `GroupIds`, and `OnPremGroups` must use `;` as the delimiter within a single CSV cell — the script splits on `;` before passing the values through.

---

## Invoke-BulkUserOffboarding.ps1

### What it does
Reads a CSV of users to offboard and, for each row, invokes `..\lifecycle\Disable-UserLifecycle.ps1` to disable the cloud account (convert mailbox to shared, remove licenses, disable devices, revoke sessions, etc., depending on which per-row boolean columns are `true`). If the row has a non-empty `SamAccountName` **and** `HybridDisableOnPrem` is `'true'`, it also invokes `..\hybrid\Disable-HybridADUser.ps1` to disable the on-prem AD object, then `..\hybrid\Start-ADSync.ps1 -PolicyType Delta` to replicate the change to the cloud. Unlike onboarding, there is no separate script-level switch gating the hybrid branch here — the per-row `HybridDisableOnPrem` column (plus a populated `SamAccountName`) is the only gate.

Boolean-like CSV columns are parsed with an internal `ConvertTo-ToolboxBool` helper, which treats a blank/whitespace cell as `$false` instead of throwing (as `[bool]::Parse()` would on an empty string) — a deliberate tolerance for common CSV data-entry gaps.

Each row is processed independently in its own try/catch. A per-row summary (`TenantName`, `UserPrincipalName`, `Status`, `Error`) is written to a timestamped `BulkUserOffboarding_<timestamp>.csv` in `..\reports`.

Expected CSV columns (see `templates\BulkUserOffboarding.csv`): `TenantName`, `HybridDisableOnPrem`, `SamAccountName`, `UserPrincipalName`, `ConvertMailboxToShared`, `RemoveLicenses`, `DisableDevices`, `RevokeSessions`, `MoveOnPremObjectToDisabledOU`, `RemoveFromAllNonDefaultGroups`.

### Parameters
| Parameter | Notes |
|---|---|
| `CsvPath` | Mandatory. Path to the input CSV — see `templates\BulkUserOffboarding.csv` for the expected format and an example row. |

### Prerequisites
- Microsoft Graph / Exchange Online modules for the cloud disable path (`..\lifecycle\Disable-UserLifecycle.ps1`).
- On-prem AD tooling plus a working sync setup for rows with `HybridDisableOnPrem = 'true'` and a populated `SamAccountName`.

### Usage
```powershell
# Offboards every user in the CSV. Rows for hybrid tenants with
# HybridDisableOnPrem='true' and a SamAccountName also get their on-prem
# AD object disabled and trigger a delta AD sync automatically — there is
# no separate script switch needed for this path (unlike onboarding).
.\Invoke-BulkUserOffboarding.ps1 -CsvPath 'D:\ADMIN SCRIPTS\M365-Admin-Toolbox-v6.2\M365-Admin-Toolbox\templates\BulkUserOffboarding.csv'
```

### Known gotchas
- Because the hybrid on-prem branch here only depends on the per-row `HybridDisableOnPrem` column (no companion script-level switch like onboarding's `-HybridCreateOnPremFirst`), double-check that column's values in the CSV before running — a stray `true` will disable an on-prem AD account and kick off a delta sync with no additional confirmation gate.

---

## Remaining scripts

The following scripts all follow the identical report-and-summary pattern described above; see the table for their required CSV columns, the operational script they call, and their key switches.

### Invoke-BulkComplianceAuditExport.ps1
Calls `..\security\Export-ComplianceAuditData.ps1` per tenant row.
```powershell
.\Invoke-BulkComplianceAuditExport.ps1 -CsvPath 'C:\Reports\tenants.csv' -StartDate '2026-06-01' -EndDate '2026-06-30' -RecordType ExchangeAdmin
```
Requires Purview/Exchange Online compliance search access (via `core\Connect-M365.ps1 -ConnectExchange -ConnectPurview` inside the operational script).

### Invoke-BulkConditionalAccessReport.ps1
Calls `..\entra\Report-ConditionalAccessPolicies.ps1` per tenant row.
```powershell
.\Invoke-BulkConditionalAccessReport.ps1 -CsvPath 'C:\Reports\tenants.csv'
```
Requires Graph read access to Conditional Access policies (`Policy.Read.All` or broader).

### Invoke-BulkLicenseInventory.ps1
Calls `..\entra\Report-LicenseInventory.ps1` per tenant row.
```powershell
.\Invoke-BulkLicenseInventory.ps1 -CsvPath 'C:\Reports\tenants.csv' -IncludeServicePlans -IncludeUserAssignments
```
Requires Graph access to subscribed SKUs / user license assignments (`Organization.Read.All`, `User.Read.All`).

### Invoke-BulkMailboxAudit.ps1
Calls `..\exchange\Audit-Mailboxes.ps1` per tenant row. Supports an optional per-row `MailboxFilter` column (defaults to `*` when blank — see `templates\BulkMailboxAudit.csv`).
```powershell
.\Invoke-BulkMailboxAudit.ps1 -CsvPath 'C:\Reports\tenants.csv' -SharedOnly
```
Requires Exchange Online read access.

### Invoke-BulkMailboxForwardingReport.ps1
Calls `..\exchange\Report-MailboxForwarding.ps1` per tenant row.
```powershell
.\Invoke-BulkMailboxForwardingReport.ps1 -CsvPath 'C:\Reports\tenants.csv' -IncludeInboxRules
```
Requires Exchange Online read access.

### Invoke-BulkPIMRoleReport.ps1
Calls `..\entra\Report-PIMRoleAssignments.ps1` per tenant row.
```powershell
.\Invoke-BulkPIMRoleReport.ps1 -CsvPath 'C:\Reports\tenants.csv'
```
Requires Graph access to PIM role assignment data (`RoleManagement.Read.Directory` or broader) — Entra ID P2 required on the tenant for PIM.

### Invoke-BulkSharedMailboxAudit.ps1
Calls `..\exchange\Report-SharedMailboxPermissions.ps1` per tenant row.
```powershell
.\Invoke-BulkSharedMailboxAudit.ps1 -CsvPath 'C:\Reports\tenants.csv' -IncludeSendAs
```
Requires Exchange Online read access.

### Invoke-BulkSharePointSites.ps1
Calls `..\sharepoint\Report-SharePointSites.ps1` per tenant row.
```powershell
.\Invoke-BulkSharePointSites.ps1 -CsvPath 'C:\Reports\tenants.csv'
```
Requires `Microsoft.Online.SharePoint.PowerShell` and SharePoint admin access.

### Invoke-BulkStaleDeviceReport.ps1
Calls `..\intune\Report-StaleDevices.ps1` per tenant row.
```powershell
.\Invoke-BulkStaleDeviceReport.ps1 -CsvPath 'C:\Reports\tenants.csv' -InactiveDays 45
```
Requires Graph/Intune device read access.

### Invoke-BulkTransportRuleReport.ps1
Calls `..\exchange\Report-TransportRules.ps1` per tenant row.
```powershell
.\Invoke-BulkTransportRuleReport.ps1 -CsvPath 'C:\Reports\tenants.csv'
```
Requires Exchange Online read access.

---

## Known gotchas (folder-wide)

- **`Invoke-BulkUserOnboarding.ps1` writes `TemporaryPassword` to its summary CSV in plaintext** — see that script's `Known gotchas` section above for the exact `TODO` comment in the source and handling recommendations.
- All 12 scripts resolve their operational-script and reports-folder paths relative to `$PSScriptRoot` (e.g. `..\reports`, `..\intune\Report-AutopilotDevices.ps1`) — run them from their location in `bulk\` (via `.\ScriptName.ps1`) rather than copying them elsewhere, or the relative paths to the operational scripts and `..\reports` will break.
- A per-row failure only stops that row — always check the `Status`/`Error` columns of the summary CSV after a run rather than assuming a script that "finished" processed every row successfully.
