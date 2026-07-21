# Teams

Microsoft Teams inventory reporting using the MicrosoftTeams module. (Expands
`docs\README-Teams-SharePoint.md`, which covers this folder jointly with `sharepoint\` — see also
`sharepoint\README.md`.)

---

## Report-TeamsInventory.ps1

### What it does
Connects to Microsoft Teams for a tenant (`Connect-M365.ps1 -ConnectTeams`), enumerates every
team via `Get-Team`, and exports one row per team to CSV. Optionally adds one additional row per
team **owner** and/or **member** (via `Get-TeamUser`), each tagged with a `RecordType` column
(`Team`, `Owner`, or `Member`) so the CSV can be filtered or pivoted per record type.

### Parameters (`param()` block)
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. Tenant name from `config\tenants.json`. |
| `OutputCsv` | CSV output path. Default `.\reports\TeamsInventory.csv`. |
| `IncludeOwners` | Switch. Add one row per team owner. |
| `IncludeMembers` | Switch. Add one row per team member. |

### Prerequisites
- `MicrosoftTeams` module (auto-installed by `Connect-M365.ps1` if missing).
- Teams Administrator (or Global Administrator) role, or an app registration with equivalent
  Teams admin API permissions if using app-only auth.

### Example usage
```powershell
.\teams\Report-TeamsInventory.ps1 -TenantName Tenant-Example-NA

.\teams\Report-TeamsInventory.ps1 -TenantName Tenant-Example-Cloud -IncludeOwners -IncludeMembers
```

### Bulk / multi-tenant equivalent
`bulk\Invoke-BulkTeamsInventory.ps1 -CsvPath .\templates\BulkTenantList.csv -IncludeOwners` runs
this report across every tenant listed in a CSV, writing one timestamped output file per tenant
into `.\reports\`.

### Known gotchas
- `-IncludeOwners`/`-IncludeMembers` each issue one `Get-TeamUser` call per team — on tenants with
  a large number of teams this can be slow and is subject to Teams cmdlet throttling; there is no
  built-in retry here (compare with `core\Retry.ps1`'s `Invoke-WithRetry`, which other scripts use
  for Graph calls).
- Archived teams are included in the export (`Archived` column reflects their state) — filter the
  CSV afterward if you only want active teams.
