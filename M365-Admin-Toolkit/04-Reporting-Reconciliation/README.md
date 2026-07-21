# 04-Reporting-Reconciliation

Two audit-style reports meant to run on a schedule (weekly/monthly) rather
than ad-hoc, catching drift that onboarding/offboarding scripts alone won't.
Both are read-only (no writes to the tenant) and both dot-source
`00-Setup\Connect-M365Services.ps1` and call `Assert-M365Connection` before
doing any Graph work, so they can be run standalone or chained after other
toolkit scripts in the same session.

---

## Get-LicenseReconciliationReport.ps1

### What it does
Pulls every user's assigned licenses, enabled status, and last sign-in
(`signInActivity`) via Microsoft Graph, cross-references against the
tenant's subscribed SKUs, and flags likely wasted license spend:
- `DISABLED_BUT_LICENSED` — account disabled but still holding paid seats
- `LICENSED_BUT_INACTIVE` — enabled, licensed, but no sign-in in the threshold window
- `ENABLED_BUT_UNLICENSED` — active account with no license (may be intentional, e.g. a service/shared mailbox account — verify before acting)
- `OK` — no issue detected

It also prints a summary of subscribed SKUs that have more seats purchased
than assigned (unused seats at or above a configurable threshold), so you
can spot over-purchased subscriptions at a glance.

### Configuration
Defaults live in the `CONFIGURATION` block near the top of the script
(after `param()`) and can be overridden per-run via parameters:

| Variable / Parameter | Default | Notes |
|---|---|---|
| `InactiveThresholdDays` | 60 | Sign-in cutoff for "inactive" |
| `ExportPath` | `.\LicenseReconciliation_<yyyyMMdd>.csv` | CSV output path |
| `ExcludedSkuPartNumbers` | `@()` (none) | SKU part numbers to exclude from waste-flagging entirely (e.g. free/trial SKUs) — config-only, not a parameter |
| `MinUnusedSeatThreshold` | 5 | Minimum unused seats on a SKU before it's surfaced in the unused-seat summary — config-only, not a parameter |

### Prerequisites
- Microsoft.Graph PowerShell SDK module
- Entra ID P1/P2 on the tenant (required for `signInActivity`)
- Graph scopes: `User.Read.All` (or broader, per `00-Setup`), plus `AuditLog.Read.All` for sign-in activity, and `Organization.Read.All` for SKU consumption data

### Usage
```powershell
# Default thresholds
.\Get-LicenseReconciliationReport.ps1

# Custom inactivity window, interactive auth (default)
.\Get-LicenseReconciliationReport.ps1 -InactiveThresholdDays 45

# Scheduled/unattended run with app-only auth
.\Get-LicenseReconciliationReport.ps1 -AuthMode AppSecret
```

---

## Get-InactiveUserReport.ps1

### What it does
Security/hygiene focused (vs. the cost focus above). Flags accounts with
no sign-in in the configured window (or that have never signed in) and —
usefully — checks whether each stale user's manager reference points to a
still-active account. A disabled manager still listed as someone's manager
is a good signal that an earlier offboarding was incomplete somewhere in
the org chain. Results are exported to CSV; enabled-but-stale accounts
(highest priority) are also printed to the console.

### Configuration
Defaults live in the `CONFIGURATION` block near the top of the script
(after `param()`) and can be overridden per-run via parameters:

| Variable / Parameter | Default | Notes |
|---|---|---|
| `InactiveThresholdDays` | 90 | Sign-in cutoff for "stale" |
| `ExportPath` | `.\InactiveUserReport_<yyyyMMdd>.csv` | CSV output path |

### Prerequisites
- Microsoft.Graph PowerShell SDK module
- Graph scopes: `User.Read.All` (or broader, per `00-Setup`), plus `AuditLog.Read.All` for `signInActivity`

### Usage
```powershell
# Default 90-day threshold
.\Get-InactiveUserReport.ps1

# Tighter 45-day threshold, certificate-based auth
.\Get-InactiveUserReport.ps1 -InactiveThresholdDays 45 -AuthMode Certificate
```

### Known gotchas
- `signInActivity` has known latency/coverage gaps for some auth flows
  (e.g. some legacy protocols) — treat "never signed in" as "worth
  checking," not gospel.
- Manager lookup loops one Graph call per stale user — on a large tenant
  this report will take noticeably longer to run than the license one.
  Consider batching via `$batchRequestContent` if this becomes slow at
  your user count.

---

## Common notes for both scripts

- `-AuthMode` accepts `Interactive` (default), `AppSecret`, or `Certificate`
  and is passed straight through to `Assert-M365Connection` /
  `Connect-M365` in `00-Setup\Connect-M365Services.ps1` — see that script's
  `$Global:M365Config` block to set tenant ID, app registration, and
  certificate/secret details for unattended runs.
- Both scripts wrap their primary Graph calls in `try/catch` and will
  write a clear error and stop rather than failing partway through if
  Graph is unreachable or the required scopes aren't consented.
- Both are safe to run repeatedly / on a schedule — they only read data
  and write a local CSV, they never modify the tenant.
