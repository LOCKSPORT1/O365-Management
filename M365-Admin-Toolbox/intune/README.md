# intune

Intune device lifecycle and reporting scripts: onboarding (categorize/sync a user's
devices), offboarding (retire/wipe/disable a leaver's devices), stale-device reporting
and cleanup, and Windows Autopilot device identity inventory.

All scripts take a mandatory `-TenantName` parameter, dot-source `..\core\Common.ps1`
(and, where they make destructive or throttle-prone calls, `..\core\Retry.ps1` /
`..\core\ErrorHandling.ps1`), and connect via `..\core\Connect-M365.ps1
-ConnectGraph -ConnectIntune`, which resolves tenant details from `config\tenants.json`.
Device management goes through the Microsoft Graph PowerShell SDK exclusively — no
deprecated `AzureAD`/`Microsoft.Graph.Intune` cmdlets are used. No script hardcodes a
tenant ID, domain, or UPN; examples use the `contoso.com` / `Tenant-Example-NA`
placeholders from `config\tenants.json`.

---

## Prerequisites

- PowerShell 7+ recommended.
- Microsoft Graph PowerShell SDK modules covering `Microsoft.Graph.DeviceManagement` and
  `Microsoft.Graph.Identity.DirectoryManagement` (auto-installed by
  `Ensure-ModuleInstalled` if missing and `ModuleAutoInstall` is enabled).
- Graph permissions: `DeviceManagementManagedDevices.ReadWrite.All` for any
  onboarding/offboarding/cleanup action; `DeviceManagementManagedDevices.Read.All` for
  read-only reporting; `DeviceManagementServiceConfig.Read.All` for Autopilot identity
  reads; `Device.ReadWrite.All` for disabling Entra device objects.
- Test destructive actions (retire, wipe, delete) against a pilot device or device group
  before running broadly — these operations cannot be undone from the toolbox side.

---

## Scripts

### Device-Onboarding.ps1

Finds a user's Intune managed device(s) (optionally narrowed to one device by name),
optionally assigns an existing Intune device category, and optionally sends an immediate
Graph sync command. Supports `-WhatIf`/`ShouldProcess`.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `UserPrincipalName` | Mandatory. Device owner's UPN. |
| `ManagedDeviceName` | Optional. Restrict to one device by `DeviceName`. |
| `DeviceCategoryDisplayName` | Optional. Must match an existing Intune device category name (see `Cloud.DefaultDeviceCategories` in tenant config). |
| `SyncDevice` | Sends an immediate Intune check-in/sync command. |

**Configuration block:** `$MaxRetryAttempts` (5), `$RetryBaseDelaySeconds` (5).

**Example**
```powershell
.\Device-Onboarding.ps1 -TenantName 'Tenant-Example-NA' -UserPrincipalName 'jdoe@contoso.com' -SyncDevice
.\Device-Onboarding.ps1 -TenantName 'Tenant-Example-NA' -UserPrincipalName 'jdoe@contoso.com' -ManagedDeviceName 'DESKTOP-ABC123' -DeviceCategoryDisplayName 'Corporate Laptops'
```

---

### Device-Offboarding.ps1

For a departing user: optionally retires and/or wipes their Intune managed devices, and
optionally disables their Entra ID device objects. Destructive — supports
`-WhatIf`/`ShouldProcess` and only acts on switches explicitly passed in.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `UserPrincipalName` | Mandatory. |
| `RetireDevices` | Retires all of the user's Intune managed devices. |
| `WipeDevices` | Factory-wipes all of the user's Intune managed devices. |
| `DisableEntraDevices` | Disables (`AccountEnabled = $false`) the user's Entra device objects. |

**Configuration block:** `$MaxRetryAttempts` (5), `$RetryBaseDelaySeconds` (5),
`$WipeKeepEnrollmentData` (false), `$WipeKeepUserData` (false).

**Example**
```powershell
.\Device-Offboarding.ps1 -TenantName 'Tenant-Example-NA' -UserPrincipalName 'jdoe@contoso.com' -WhatIf
.\Device-Offboarding.ps1 -TenantName 'Tenant-Example-NA' -UserPrincipalName 'jdoe@contoso.com' -RetireDevices -DisableEntraDevices
```

---

### Report-StaleDevices.ps1

Read-only. Exports Intune managed devices whose `LastSyncDateTime` is older than the
configured threshold. Filtering is done client-side (Graph's server-side `$filter` on
`lastSyncDateTime` is not reliable across all SDK versions/tenants). Can be dot-sourced
by `Cleanup-StaleDevices.ps1` to produce a pre-cleanup snapshot.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `InactiveDays` | Days since last sync before a device counts as stale. Default **30**. |
| `OutputCsv` | Default `reports\StaleDevices.csv` under the toolbox root. |

**Configuration block:** `$DefaultInactiveDays` (30), `$DefaultOutputCsv`.

**Example**
```powershell
.\Report-StaleDevices.ps1 -TenantName 'Tenant-Example-NA' -InactiveDays 60 -OutputCsv 'C:\Reports\StaleDevices.csv'
```

---

### Cleanup-StaleDevices.ps1

Destructive. Finds stale devices the same way `Report-StaleDevices.ps1` does, always
writes a timestamped pre-cleanup CSV snapshot first (for review/rollback reference), then
retires or deletes each candidate. Supports `-WhatIf`/`ShouldProcess`.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `InactiveDays` | Days since last sync before a device counts as stale. Default **90** (intentionally more conservative than the 30-day reporting default, since this script acts on the results). |
| `Action` | `Retire` (default) or `Delete`. |

**Configuration block:** `$DefaultInactiveDays` (90), `$MaxRetryAttempts` (5),
`$RetryBaseDelaySeconds` (5).

**Example**
```powershell
.\Cleanup-StaleDevices.ps1 -TenantName 'Tenant-Example-NA' -WhatIf
.\Cleanup-StaleDevices.ps1 -TenantName 'Tenant-Example-NA' -InactiveDays 120 -Action Retire
```

---

### Report-AutopilotDevices.ps1

Read-only. Exports every Windows Autopilot device identity (serial number, group tag,
manufacturer, model, enrollment state, last contact) registered in the tenant. Does not
modify any devices or Autopilot registrations.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `OutputCsv` | Default `reports\AutopilotDevices.csv` under the toolbox root. |

**Configuration block:** `$DefaultOutputCsv`.

**Example**
```powershell
.\Report-AutopilotDevices.ps1 -TenantName 'Tenant-Example-NA' -OutputCsv 'C:\Reports\Autopilot.csv'
```

---

### Autopilot-DeploymentSetup.ps1

Standalone script — manages its own Microsoft Graph connection rather than
`core\Connect-M365.ps1` (same pattern as `entra\Audit-LicenseWaste.ps1` and
`entra\Audit-StaleAccounts.ps1`). Builds the department-based Autopilot deployment
structure: for each row in its `$Departments` table, creates a dynamic Entra ID
security group keyed on Autopilot Group Tag, a Windows Autopilot deployment
profile, and the assignment linking them. Never deletes anything — safe to re-run,
existing groups/profiles are detected by name and skipped. Ships with generic
example departments — replace with your organization's real breakdown in
`$Departments` before running for real.

**Parameters**
| Parameter | Notes |
|---|---|
| `DryRun` | Preview mode — prints every group/profile/assignment that would be created, including the full JSON payload, without making changes. Always run this first. |
| `Only` | Restrict the run to a single department, matched by its `Key` field. |
| `LogPath` | CSV summary of every group/profile ID touched. Defaults to `AutopilotSetup-Log-<timestamp>.csv`. Not written in `-DryRun`. |

**Configuration block:** `$GraphApiVersion` (v1.0), `$DefaultJoinType`
(`HybridAzureADJoined` by default — change to `AzureADJoined` for cloud-only
tenants), `$DefaultOobeDefaults` (OOBE screen behavior), `$Departments` table.

**Required Graph permissions:** `Group.ReadWrite.All`, `Device.ReadWrite.All`,
`DeviceManagementServiceConfig.ReadWrite.All`, `DeviceManagementConfiguration.ReadWrite.All`.

**Example**
```powershell
.\Autopilot-DeploymentSetup.ps1 -DryRun
.\Autopilot-DeploymentSetup.ps1
.\Autopilot-DeploymentSetup.ps1 -Only "Sales"
```

Full runbook (prerequisites, device registration steps, adding departments,
verification, rollback): `docs\Autopilot-Deployment-Runbook.md` (also available as
the formatted `docs\Windows-Autopilot-Setup-Guide.docx`).

---

## Notes

- All device actions connect to Graph at runtime via `Connect-M365.ps1
  -ConnectGraph -ConnectIntune`; there is no separate Intune-specific auth path.
  (`Autopilot-DeploymentSetup.ps1` is the one exception — it's standalone, see above.)
- Always test retire/wipe/delete actions on a pilot device or device group before
  running broadly.

## Related

- `docs\README-Intune.md` — original short-form reference doc for this folder.
- `docs\Autopilot-Deployment-Runbook.md` / `docs\Windows-Autopilot-Setup-Guide.docx` —
  full Autopilot deployment walkthrough.
