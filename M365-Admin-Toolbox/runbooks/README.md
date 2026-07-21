# Runbooks

Reference pattern for running the toolbox's multi-tenant bulk workflows unattended from Azure
Automation (or any external scheduler that can invoke a `.ps1` file). These scripts are meant to
be copied and adapted per environment, not run against production tenants as-is.

---

## AzureAutomation-Example.ps1

### What it does
Chains three bulk reports — license inventory, conditional access policies, and Autopilot
devices — across every tenant listed in a CSV, then generates a combined HTML dashboard via
`reporting\New-HtmlDashboardReport.ps1`. All child scripts are invoked using paths resolved
relative to this script's own location (`$PSScriptRoot`), so it behaves the same regardless of
Azure Automation's working directory at runtime.

### Parameters (`param()` block)
| Parameter | Notes |
|---|---|
| `TenantListCsv` | CSV of tenants to process (needs a `TenantName` column matching `config\tenants.json`). Default `.\templates\BulkTenantList.csv`. |
| `ReportFolder` | Folder where per-tenant CSVs land and where the dashboard scans from. Default `.\reports`. |
| `DashboardHtmlPath` | Output path for the combined HTML dashboard. Default `.\reports\RunbookDashboard.html`. |
| `DashboardLabel` | Display label shown at the top of the dashboard for this run. Default `'Runbook-MultiTenant'`. |

### Prerequisites
- **App-only (certificate) authentication configured in `config\tenants.json`** for every tenant
  in the CSV — this runbook has no interactive sign-in path, and Azure Automation Sandbox/Hybrid
  Worker execution cannot service an interactive prompt.
- Microsoft.Graph.Authentication module (and any workload-specific modules used by the wrapped
  bulk scripts) available in the Azure Automation account or Hybrid Runbook Worker.
- `templates\BulkTenantList.csv` (or an equivalent CSV) populated with the tenants to process.

### Example usage
```powershell
.\runbooks\AzureAutomation-Example.ps1 -TenantListCsv .\templates\BulkTenantList.csv
```

### Known gotchas
- Replace delegated auth with app-only auth (`AppRegistration.UseAppOnly = true` plus a client ID
  and certificate thumbprint) in `config\tenants.json` before scheduling this unattended — this
  is called out directly in the script's own comments.
- Azure Automation sandboxes are ephemeral; any certificate used for app-only auth needs to be
  imported into the Automation Account's certificate store (or referenced via an Automation
  connection), not just the local machine store.
