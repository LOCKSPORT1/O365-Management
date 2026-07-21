# Scheduled tasks

Windows Task Scheduler equivalents of the `runbooks\` folder: an example daily reporting script
plus a small helper to register any toolbox script as a recurring scheduled task.

---

## Example-DailyReporting.ps1

### What it does
Runs the full set of multi-tenant bulk reports — license inventory, shared mailbox audit, stale
device report, Teams inventory, SharePoint sites, Autopilot devices, and conditional access
policies — for every tenant in a CSV, then builds a combined HTML dashboard. This is the script
you point `Register-AdminToolboxScheduledTask.ps1` at for a one-shot daily rollup. All child
scripts are invoked using paths resolved relative to this script's own location, so it behaves
the same regardless of the scheduler's working directory.

### Parameters (`param()` block)
| Parameter | Notes |
|---|---|
| `TenantListCsv` | CSV of tenants to process. Default `.\templates\BulkTenantList.csv`. |
| `ReportFolder` | Folder where per-tenant CSVs land and where the dashboard scans from. Default `.\reports`. |
| `DashboardHtmlPath` | Output path for the combined HTML dashboard. Default `.\reports\AdminDashboardReport.html`. |
| `DashboardLabel` | Display label shown at the top of the dashboard. Default `'MultiTenant'`. |
| `StaleDeviceInactiveDays` | Inactivity threshold (days) passed to the stale device report. Default `45`. |

### Prerequisites
- App-only (certificate) authentication configured per tenant in `config\tenants.json` — scheduled
  tasks typically run under a service account with no interactive session to complete a sign-in.
- Modules required by each wrapped bulk script (Graph, Exchange, Teams, SharePoint, Intune as
  applicable) installed for the account the task runs as.
- `templates\BulkTenantList.csv` populated with the tenants to process.

### Example usage
```powershell
.\scheduled-tasks\Example-DailyReporting.ps1 -TenantListCsv .\templates\BulkTenantList.csv
```

---

## Register-AdminToolboxScheduledTask.ps1

### What it does
Thin wrapper around `New-ScheduledTaskAction` / `New-ScheduledTaskTrigger` /
`New-ScheduledTaskPrincipal` / `Register-ScheduledTask` that registers a daily Windows Scheduled
Task to run any given `.ps1` file. Validates `-ScriptPath` exists before attempting registration
and wraps the registration call in try/catch so failures surface a clear error.

### Parameters (`param()` block)
| Parameter | Notes |
|---|---|
| `TaskName` | Mandatory. Name to register the task under in Task Scheduler. |
| `ScriptPath` | Mandatory. Full path to the `.ps1` script the task should execute. |
| `Arguments` | Additional command-line arguments passed to the script. Default empty. |
| `StartTime` | Daily start time, `HH:mm` 24-hour format. Default `'02:00'`. |

### Configuration block
| Variable | Purpose |
|---|---|
| `$PowerShellExecutable` | Executable used to launch the script — `'powershell.exe'` (Windows PowerShell 5.1) by default, or `'pwsh.exe'` for PowerShell 7+ (recommended, since the toolbox targets PS7 — make sure `pwsh.exe` is installed and on PATH for the account the task runs as). |
| `$RunAsUserId` | Account the scheduled task principal runs under. Default `'SYSTEM'`. |

### Prerequisites
- Must be run elevated (`Register-ScheduledTask` requires administrator rights).
- If running under a non-SYSTEM account, that account needs local rights to run PowerShell and
  access to any certificates used for app-only M365 authentication.

### Example usage
```powershell
.\scheduled-tasks\Register-AdminToolboxScheduledTask.ps1 `
    -TaskName 'M365Toolbox-DailyReporting' `
    -ScriptPath 'C:\Tools\M365-Admin-Toolbox\scheduled-tasks\Example-DailyReporting.ps1' `
    -StartTime '02:00'
```

### Known gotchas
- Interactive/delegated Graph auth will not work under the `SYSTEM` account or any account
  without an interactive session — use app-only (certificate) authentication for any script
  registered this way.
- Run the task manually once from Task Scheduler ("Run") after registering it, to confirm auth
  and module availability under the "Run As" account before waiting for the next scheduled run.
