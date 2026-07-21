# Public functions

Advanced-function wrappers exposed when the toolbox is imported as a PowerShell module
(`Import-Module .\M365AdminToolbox.psd1`). Each function is a thin, documented wrapper around
one of the loose operational scripts elsewhere in the repo (`core`, `exchange`, `lifecycle`,
`bulk`, `entra`, `security`), so module users get discoverable cmdlet-style commands
(`Get-Command -Module M365AdminToolbox`, `Get-Help Invoke-M365UserOnboarding`) instead of having
to know the underlying file layout.

All functions in this file are listed in `FunctionsToExport` in `M365AdminToolbox.psd1` and are
dot-sourced automatically by `M365AdminToolbox.psm1` on module import.

---

## Public-Functions.ps1

### What it does
Defines seven advanced functions, each forwarding its bound parameters (`@PSBoundParameters`) to
the corresponding script, resolved via `Get-ToolboxRoot` so it works regardless of the caller's
working directory.

| Function | Wraps | Notes |
|---|---|---|
| `Invoke-M365Connect` | `core\Connect-M365.ps1` | Connects to Graph/Exchange/Purview/Teams/SharePoint/Azure/Intune for a tenant |
| `Invoke-M365MailboxAudit` | `exchange\Audit-Mailboxes.ps1` | Exports mailbox audit settings to CSV |
| `Invoke-M365UserOnboarding` | `lifecycle\New-UserLifecycle.ps1` | Creates and onboards a user; supports `-WhatIf`/`-Confirm` |
| `Invoke-M365UserOffboarding` | `lifecycle\Disable-UserLifecycle.ps1` | Offboards a user; supports `-WhatIf`/`-Confirm` |
| `Invoke-M365BulkOnboarding` | `bulk\Invoke-BulkUserOnboarding.ps1` | Runs bulk onboarding from a CSV |
| `Invoke-M365LicenseInventoryReport` | `entra\Report-LicenseInventory.ps1` | Exports license inventory (and optionally assignments) to CSV |
| `Invoke-M365SecurityAuditExport` | `security\Export-ComplianceAuditData.ps1` | Exports unified audit log data for a date range |

`Invoke-M365UserOnboarding` and `Invoke-M365UserOffboarding` use `[CmdletBinding(SupportsShouldProcess)]`
and only call through to the underlying script if `$PSCmdlet.ShouldProcess(...)` confirms —
use `-WhatIf` to preview either operation safely.

### Parameters
Each function exposes the same parameters as the script it wraps. `TenantName` (a name from
`config\tenants.json`) is required on every function except `Invoke-M365BulkOnboarding`, which
takes a `-CsvPath` instead because it operates across multiple tenants listed in the CSV.

### Prerequisites
- The module manifest must be importable: `Import-Module .\M365AdminToolbox.psd1 -Force`.
- Same module prerequisites as the wrapped scripts (Microsoft.Graph.Authentication,
  ExchangeOnlineManagement, etc.) — see the root `README.md` and `docs\README-Core.md`.
- `config\tenants.json` populated with the tenant(s) you intend to pass via `-TenantName`.

### Example usage
```powershell
Import-Module .\M365AdminToolbox.psd1 -Force

Invoke-M365Connect -TenantName Tenant-Example-Cloud -ConnectGraph -ConnectExchange

Invoke-M365MailboxAudit -TenantName Tenant-Example-NA -SharedOnly

Invoke-M365UserOnboarding -TenantName Tenant-Example-Cloud -DisplayName 'Jane Doe' `
    -UserPrincipalName jane@example.com -MailNickname jane -WhatIf

Invoke-M365SecurityAuditExport -TenantName Tenant-Example-NA `
    -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date)
```
