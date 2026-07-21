# Samples

A minimal, copy/paste starting point for writing new toolbox scripts. Unlike `runbooks\` (bulk,
multi-tenant, unattended) this is a single-tenant, interactive example meant to be read and
edited, not scheduled.

---

## Sample-Runbook.ps1

### What it does
Dot-sources `core\Connect-M365.ps1` for one tenant, requesting Graph, Exchange, Purview, Azure,
and Intune connectivity in a single call. The rest of the file is commented-out example calls
showing how to invoke other operational scripts (`exchange\Audit-Mailboxes.ps1`,
`lifecycle\Disable-UserLifecycle.ps1`) once connected.

### Parameters (`param()` block)
| Parameter | Notes |
|---|---|
| `TenantName` | Tenant name from `config\tenants.json`. Default `'Tenant-Example-NA'` (placeholder tenant — replace with your own). |

### Prerequisites
- A tenant entry in `config\tenants.json` matching `-TenantName`.
- Whatever modules the workloads you connect to require (see `docs\README-Core.md` and the root
  `README.md` for the full module list).

### Example usage
```powershell
# Connect only — then uncomment/adapt the example lines in the script for your task
.\samples\Sample-Runbook.ps1 -TenantName Tenant-Example-NA
```

### Notes
- This script is intentionally inert beyond the connection step — the follow-up commands are
  commented out so nothing destructive runs by default. Uncomment and adjust them (including
  replacing the placeholder `user@example.com`) before using it for real work.
