# SharePoint

SharePoint Online site inventory reporting using the SharePoint Online Management Shell.
(Expands `docs\README-Teams-SharePoint.md`, which covers this folder jointly with `teams\` — see
also `teams\README.md`.)

---

## Report-SharePointSites.ps1

### What it does
Connects to the SharePoint Online admin service for a tenant (`Connect-M365.ps1 -ConnectSharePoint`,
which derives the `https://<tenant>-admin.sharepoint.com` admin URL from the tenant's
`PrimaryDomain` in `config\tenants.json`), then exports one row per site to CSV: URL, title,
owner, template, current storage usage, lock state, and sharing capability.

### Parameters (`param()` block)
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. Tenant name from `config\tenants.json`. |
| `OutputCsv` | CSV output path. Default `.\reports\SharePointSites.csv`. |
| `SiteLimit` | Maximum number of sites to retrieve (`Get-SPOSite -Limit`). Default `'All'` — set to a number to cap results on very large tenants. |

### Prerequisites
- `Microsoft.Online.SharePoint.PowerShell` module (auto-installed by `Connect-M365.ps1` if missing).
- SharePoint Administrator (or Global Administrator) role, or an app registration with equivalent
  SharePoint admin API permissions if using app-only auth.
- Tenant entry in `config\tenants.json` with a valid `PrimaryDomain` (used to build the admin
  center URL).

### Example usage
```powershell
.\sharepoint\Report-SharePointSites.ps1 -TenantName Tenant-Example-NA

.\sharepoint\Report-SharePointSites.ps1 -TenantName Tenant-Example-Cloud `
    -OutputCsv .\reports\SPOSites-Cloud.csv
```

### Bulk / multi-tenant equivalent
`bulk\Invoke-BulkSharePointSites.ps1 -CsvPath .\templates\BulkTenantList.csv` runs this report
across every tenant listed in a CSV, writing one timestamped output file per tenant into
`.\reports\`.

### Known gotchas
- `Get-SPOSite` by default only returns standard site collections — OneDrive and certain system
  site types require additional switches not currently exposed by this script.
- Large tenants (thousands of sites) can take several minutes to enumerate; consider narrowing
  with `-SiteLimit` for a quick spot check.
