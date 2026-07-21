# azure

Azure subscription context helper for Azure Automation / Az.Accounts-based tasks.

---

## Azure-SubscriptionContext.ps1

### What it does
Connects to Azure for the specified tenant (via `core\Connect-M365.ps1 -ConnectAzure`) and sets the active `Az` PowerShell context to a specific subscription, or to the first subscription returned by `Get-AzSubscription` if none is specified. Returns the resulting `Az` context object (`Get-AzContext`) to the pipeline after logging success via `Write-ToolboxLog`.

This script is the toolbox's designated entry point for anything that needs an active Azure subscription context — for example, Azure Automation runbooks or ad-hoc Azure resource scripts that live alongside the M365-focused parts of the toolbox.

### Parameters
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. Must match a `Name` entry in `config\tenants.json` (e.g. `Tenant-Example-NA`). |
| `SubscriptionId` | Optional. The Azure subscription ID (GUID) to set as the active context. If omitted, the first subscription returned by `Get-AzSubscription` for the connected account is used. |

### Prerequisites
- `Az.Accounts` module (auto-installed via `Ensure-ModuleInstalled` when `Connect-M365.ps1` is called with `-ConnectAzure`).
- Azure connectivity is established entirely through `core\Connect-M365.ps1`'s `-ConnectAzure` switch — this script dot-sources `core\Common.ps1` and then dot-sources and invokes `core\Connect-M365.ps1 -TenantName $TenantName -ConnectAzure` itself. You do not need to (and should not need to) connect to Azure separately before running this script.
- The signed-in account/service principal must have access to at least one Azure subscription under the target tenant.

### Usage
```powershell
# Connects to Azure for Tenant-Example-NA and sets the context to the
# first available subscription.
.\Azure-SubscriptionContext.ps1 -TenantName 'Tenant-Example-NA'

# Connects to Azure for Tenant-Example-Cloud and sets the context to a
# specific subscription.
.\Azure-SubscriptionContext.ps1 -TenantName 'Tenant-Example-Cloud' -SubscriptionId '00000000-0000-0000-0000-000000000000'
```

### Known gotchas
- If no `-SubscriptionId` is supplied **and** `Get-AzSubscription` returns no subscriptions for the connected account, the script **throws** (it does not just warn and continue):
  > `No Azure subscriptions were found for tenant '<TenantName>' and no -SubscriptionId was specified. Verify the connected account has access to at least one subscription.`

  Callers that want a soft-fail behavior (e.g. bulk orchestration across many tenants) should wrap calls to this script in their own `try/catch`.
- When `-SubscriptionId` is omitted, "the first subscription returned by `Get-AzSubscription`" is whatever order Azure Resource Manager returns for that account — if an account has access to multiple subscriptions under the tenant, don't assume a specific one will be selected. Pass `-SubscriptionId` explicitly whenever the target subscription matters.
