# Reporting

Rolls up the CSV output of other toolbox scripts (bulk, security, Teams, SharePoint, etc.) into
a single self-contained HTML dashboard, so you have one file to open/share instead of a folder
full of CSVs.

---

## New-HtmlDashboardReport.ps1

### What it does
Scans a report folder for `*.csv` files, sorts them by last-write time, and renders a dark-themed
HTML page listing each file's name, last-updated timestamp, and size. Does not read or interpret
the contents of the CSVs — it only indexes what's on disk, so run your reporting/bulk scripts
first and point this at the same output folder afterward.

### Parameters (`param()` block)
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. Display label only — shown in the dashboard header and in log lines. Does not have to match `config\tenants.json` exactly (useful for multi-tenant rollup runs). |
| `ReportFolder` | Folder to scan for `*.csv` files. Default `.\reports`. |
| `OutputHtml` | Path to write the generated HTML file. Default `.\reports\AdminDashboardReport.html`. |

### Configuration block
| Variable | Purpose |
|---|---|
| `$ReportTitle` | Heading text shown at the top of the generated dashboard page. Default `'Admin Dashboard Report'`. |

### Prerequisites
- No M365 connection required — this script only reads the local filesystem.
- `core\Common.ps1` (dot-sourced automatically) for `Ensure-Directory` / `Write-ToolboxLog`.

### Example usage
```powershell
# Basic dashboard over the default .\reports folder
.\reporting\New-HtmlDashboardReport.ps1 -TenantName Tenant-Example-NA

# Custom folder/output path and a renamed dashboard title
.\reporting\New-HtmlDashboardReport.ps1 -TenantName Tenant-Example-Cloud `
    -ReportFolder .\reports -OutputHtml .\reports\MultiTenantDashboard.html
```

### Known gotchas
- The dashboard only lists files that already exist in `ReportFolder` at the moment it runs —
  run it last in any pipeline of reporting scripts (see `runbooks\` and `scheduled-tasks\` for
  examples that do this).
- It does not delete or roll over old CSVs; the folder will accumulate historical reports unless
  you clean it up separately.
