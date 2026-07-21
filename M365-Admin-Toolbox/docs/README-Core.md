# Core scripts

## Common.ps1
Provides shared helper functions:
- `Get-ToolboxConfig`
- `Get-TenantConfig`
- `Ensure-ModuleInstalled`
- `Write-ToolboxLog`
- `Resolve-LicenseSkuIds`

## Connect-M365.ps1
This is the mandatory connection bootstrap used by every operational script.

### Purpose
- Reads the tenant config from JSON
- Ensures required PowerShell modules are installed
- Connects to Graph, Exchange, Purview, Teams, SharePoint, Azure, and Intune when requested
- Supports interactive and certificate-based app-only Graph login

### Parameters
- `TenantName` - required, must match a tenant in `config/tenants.json`
- `ConnectGraph`
- `ConnectExchange`
- `ConnectPurview`
- `ConnectTeams`
- `ConnectSharePoint`
- `ConnectAzure`
- `ConnectIntune`
- `UseAppOnly`
- `GraphScopes`

### Example
```powershell
.\core\Connect-M365.ps1 -TenantName Tenant-Example-Cloud -ConnectGraph -ConnectExchange -ConnectIntune
```

### Why this script is always imported at the top
Your requirement was that no task script can assume connectivity is already present. For that reason, every operational script dot-sources or invokes the connector at the beginning.


## Bulk orchestration design
The bulk scripts do not bypass the connector. They call the same operational scripts used for one-off administration, which keeps connection logic and behavior consistent.


## Additional service connectors
The connector already supports Teams and SharePoint flags, and the v4 scripts use those switches directly when those workloads are required.


## Module packaging
The package now includes a root module and manifest so it can be imported as a module instead of only being run as loose scripts.

### Import example
```powershell
Import-Module .\M365AdminToolbox.psd1 -Force
```
