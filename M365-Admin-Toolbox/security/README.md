# Security and hardening

Compliance/audit data export scripts plus the toolbox's production-hardening reference material.
This folder covers "what to run to collect security-relevant data" and "what to check before you
trust this toolbox running unattended in production." (Consolidates and supersedes
`docs\README-Security.md` and `docs\README-Hardening.md` — see those files for the original
short-form notes.)

---

## Export-ComplianceAuditData.ps1

### What it does
Connects to Exchange Online for a tenant and runs `Search-UnifiedAuditLog` over a date range and
record type, exporting matching records (creation date, user IDs, operations, record type, raw
audit data) to CSV. Warns (but does not fail) if the result count hits the configured cap, since
that indicates results may be truncated.

### Parameters (`param()` block)
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. Tenant name from `config\tenants.json`. |
| `StartDate` | Mandatory. Start of the audit log search window. |
| `EndDate` | Mandatory. End of the audit log search window. |
| `OutputCsv` | CSV output path. Default `.\reports\ComplianceAuditData.csv`. |
| `RecordType` | Unified audit log record type (see `Search-UnifiedAuditLog -RecordType`). Default `'ExchangeAdmin'`. |
| `ResultSize` | Maximum records per search (`Search-UnifiedAuditLog` itself caps at 5000). Default `5000`. |

### Prerequisites
- Exchange Online / compliance role sufficient to run `Search-UnifiedAuditLog` (typically View-Only
  Audit Logs or Audit Logs role in Exchange Online, or Compliance Administrator in Purview).
- Unified audit logging enabled for the tenant.
- `ExchangeOnlineManagement` module (auto-installed by `Connect-M365.ps1` if missing).

### Example usage
```powershell
.\security\Export-ComplianceAuditData.ps1 -TenantName Tenant-Example-NA `
    -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date)

.\security\Export-ComplianceAuditData.ps1 -TenantName Tenant-Example-Cloud `
    -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) `
    -RecordType 'AzureActiveDirectory' -OutputCsv .\reports\AadAudit.csv
```

### Known gotchas
- If the result count reaches `ResultSize`, results are likely truncated — narrow the date range
  or split the search into smaller windows rather than trusting the export is complete.
- Unified audit log data typically only goes back 90 days on standard plans (longer with certain
  retention/compliance add-ons).

---

## Export-DefenderO365Scaffold.ps1

### What it does
Does **not** call any Defender for Office 365 cmdlets. It writes a placeholder text file noting
the intended purpose and reminders for building out real Defender for Office 365 reporting
(threat, quarantine, policy data, etc.), since the exact cmdlets/APIs and licensing vary by
tenant and Defender plan.

### Parameters (`param()` block)
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. Tenant name from `config\tenants.json` — included in the scaffold text. |
| `OutputTxt` | Output path for the scaffold file. Default `.\reports\DefenderO365Scaffold.txt`. |

### Prerequisites
- None beyond the base toolbox (`core\Common.ps1`) — this script does not connect to any service.

### Example usage
```powershell
.\security\Export-DefenderO365Scaffold.ps1 -TenantName Tenant-Example-NA
```

### Extending this scaffold
Replace the placeholder content with real Defender for Office 365 cmdlets/Graph security API
calls once you've confirmed the specific licensing and permissions available in your tenant
(e.g. Microsoft Defender for Office 365 Plan 1/2, Microsoft 365 Defender unified role-based
access control).

---

## Invoke-HardeningChecklist.ps1

### What it does
Exports a static text checklist of production hardening recommendations for this toolbox —
authentication model, secrets storage, code signing, logging, least privilege, retry/throttling
behavior, testing, output storage, certificate rotation, and scheduled task/runbook review.

### Parameters (`param()` block)
| Parameter | Notes |
|---|---|
| `OutputTxt` | Output path for the checklist file. Default `.\reports\HardeningChecklist.txt`. |

### Example usage
```powershell
.\security\Invoke-HardeningChecklist.ps1
.\security\Invoke-HardeningChecklist.ps1 -OutputTxt .\reports\PreProdHardeningChecklist.txt
```

---

## Audit-PrivilegedAccess.ps1

### What it does
Standalone, self-contained script (not built on `core\Connect-M365.ps1` /
`config\tenants.json` — it manages its own `Connect-MgGraph` connection, AD module check,
and module installs). Audits membership of your highest-privilege AD groups (default:
Domain Admins, Enterprise Admins, Schema Admins) and Entra ID directory roles (default:
Global Administrator, Privileged Role Administrator, User Administrator, License
Administrator), and flags any privileged account that's disabled, stale (same
inactivity logic as `access-profile`'s stale-account checks, tighter 60-day default), a
guest/external account, or has no MFA method registered — the last being the
highest-priority finding this script produces. Read-only; never removes anyone from a
group or role.

### Parameters (`param()` block)
| Parameter | Notes |
|---|---|
| `AdPrivilegedGroups` | AD group names to audit. Default `Domain Admins, Enterprise Admins, Schema Admins`. |
| `EntraPrivilegedRoles` | Entra directory role display names to audit. Default `Global Administrator, Privileged Role Administrator, User Administrator, License Administrator`. |
| `InactiveDays` | Staleness threshold in days. Default `60`. |
| `ReportPath` | Folder for the CSV report and transcript log. Default `.\AuditReports`. |
| `AutoInstallMissingModules` | Auto-install missing PSGallery modules instead of prompting. |

### Prerequisites
- `ActiveDirectory` RSAT module (not auto-installable — the script tells you how to get it
  if missing).
- Microsoft Graph PowerShell SDK: `Microsoft.Graph.Users`,
  `Microsoft.Graph.Identity.DirectoryManagement`, `Microsoft.Graph.Identity.SignIns`.
- Graph scopes: `User.Read.All`, `AuditLog.Read.All`, `RoleManagement.Read.Directory`,
  `UserAuthenticationMethod.Read.All`.

### Example usage
```powershell
.\Audit-PrivilegedAccess.ps1
.\Audit-PrivilegedAccess.ps1 -EntraPrivilegedRoles "Global Administrator", "Exchange Administrator", "Security Administrator"
```

### Known gotchas
- The MFA check only confirms a registered authentication method beyond a password — it
  cannot confirm Conditional Access or per-user MFA is actually *enforced*.
- A flagged group/role assignment isn't automatically wrong (service/automation accounts
  can legitimately need standing privileged access) — the point is to make sure it's a
  deliberate, reviewed state.

---

## Hardening reference: other `core\` scripts

These live in `core\`, not `security\`, but are the supporting mechanisms the checklist above
refers to:

| Script | Purpose |
|---|---|
| `core\Logging.ps1` | `Start-ToolboxTranscript` / `Stop-ToolboxTranscript` — wraps `Start-Transcript` for full-session transcript logging under `logs\transcripts\`. |
| `core\ErrorHandling.ps1` | `Invoke-ToolboxSafely` — centralized try/catch/finally wrapper that logs success/failure via `Write-ToolboxLog` and optionally rethrows. |
| `core\Retry.ps1` | `Invoke-WithRetry` — retry/backoff handling for Graph throttling (HTTP 429) and other transient failures. |
| `core\Secrets.ps1` | `Set-ToolboxSecret` / `Get-ToolboxSecret` — helpers built on PowerShell SecretManagement/SecretStore for storing credentials outside of script files. |
| `core\CodeSigning.ps1` | `Sign-ToolboxScripts` — bulk Authenticode signing helper using a certificate from `Cert:\CurrentUser\My` and an RFC3161 timestamp server. |

### Hardening prerequisites
- A code-signing certificate (for `Sign-ToolboxScripts`) issued by your organization's PKI or a
  trusted CA, imported into `Cert:\CurrentUser\My` (or the relevant automation identity's store).
- `Microsoft.PowerShell.SecretManagement` and `Microsoft.PowerShell.SecretStore` modules (for
  `core\Secrets.ps1` — auto-installed via `Ensure-ModuleInstalled` when first used).
- App registration(s) with certificate-based authentication configured in `config\tenants.json`
  for any unattended (scheduled task / runbook) use.

### Testing direction
Use Pester (see `tests\README.md`) to validate module import and confirm key exported functions
are available before promoting a release.
