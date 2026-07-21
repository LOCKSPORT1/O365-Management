# core

Shared helper functions and the connection bootstrap that nearly every other script in the toolbox dot-sources before doing any tenant work.

All scripts in `core\` are dot-sourced libraries, not standalone entry points (`Connect-M365.ps1` is the one exception — it takes its own `param()` block and can be dot-sourced *with* arguments, as shown in its usage examples below). Nothing in this folder talks to a specific tenant on its own; it just gives every other script in the toolbox a consistent way to find config, connect, log, retry, store secrets, and sign code.

---

## Common.ps1

### What it does
The foundation file. Nearly every other script (including the rest of `core\`) dot-sources this first. Defines tenant-neutral utility functions:

| Function | Purpose |
|---|---|
| `Get-ToolboxRoot` | Resolves and returns the toolbox root folder (one level above `core\`). |
| `Get-ConfigPath` | Returns the full path to `config\tenants.json` under the toolbox root. |
| `Get-ToolboxConfig` | Reads and JSON-parses `config\tenants.json`. Throws if the file is missing. |
| `Get-TenantConfig` | Looks up a single tenant object by `-TenantName` from `Get-ToolboxConfig`. Throws if the name isn't found. |
| `Ensure-Directory` | Creates a directory (and parents) if it doesn't already exist. |
| `Write-ToolboxLog` | Writes a timestamped, leveled log line to both the console and `logs\toolbox.log` (or a custom `-LogName`). |
| `Ensure-ModuleInstalled` | Installs a PowerShell module (`-Scope CurrentUser`) if it isn't already present, or upgrades it if a `-MinimumVersion` isn't met. This is the auto-install helper referenced throughout the toolbox. |
| `Resolve-LicenseSkuIds` | Resolves an array of `-SkuPartNumbers` (e.g. `ENTERPRISEPACK`) to Graph SKU GUIDs via `Get-MgSubscribedSku`. Requires an active Graph connection. |
| `Resolve-ToolboxUserPrincipalName` | Given a raw `-UserPrincipalName` value and a tenant object, returns it unchanged if it already contains `@`, or appends the tenant's `PrimaryDomain` if it's just a bare local part (e.g. `jdoe` → `jdoe@contoso.com`). Used by `lifecycle\New-UserLifecycle.ps1` and `hybrid\New-HybridADUser.ps1` so onboarding never depends on someone typing/picking the right domain by hand — it always comes from `config\tenants.json`. |

### Parameters
This file defines functions only and takes no parameters itself. See each function's own parameters above.

### Usage
```powershell
. (Join-Path $PSScriptRoot 'core\Common.ps1')

$tenant = Get-TenantConfig -TenantName 'Tenant-Example-NA'
Write-ToolboxLog -TenantName 'Tenant-Example-NA' -Level INFO -Message 'Starting nightly report run.'
Ensure-ModuleInstalled -ModuleName 'Microsoft.Graph.Authentication'
$skuIds = Resolve-LicenseSkuIds -SkuPartNumbers 'ENTERPRISEPACK','SPE_E5'
```

### Known gotchas
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` are set at the top of this file. Because it's dot-sourced into the caller's scope, any script that dot-sources `Common.ps1` inherits these settings for the rest of its own execution too.
- Function names and signatures in this file are treated as a stable contract — nearly everything else in the toolbox depends on them, so they intentionally haven't changed across versions.

---

## Connect-M365.ps1

### What it does
The mandatory connection bootstrap. Dot-sources `Common.ps1` and `Retry.ps1`, resolves the requested tenant from `config\tenants.json`, ensures the PowerShell modules needed for the requested services are installed, and connects to Microsoft Graph, Exchange Online, Purview/Security & Compliance (IPPS), Microsoft Teams, SharePoint Online, and/or Azure based on which `-Connect*` switches are passed. Returns a `pscustomobject` summarizing the tenant that was connected to (`TenantName`, `TenantId`, `Domain`, `ExchangeOrganization`, `OnPremEnabled`, `Region`, `LocationName`).

Unlike the rest of `core\`, this file is itself invoked with arguments (dot-sourced *with* a param block) rather than just providing functions — operational scripts across the toolbox call it near the top with the specific `-Connect*` switches they need.

### Parameters
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. Must match a `Name` entry in `config\tenants.json` (e.g. `Tenant-Example-NA`). |
| `ConnectGraph` | Connects to Microsoft Graph (`Connect-MgGraph`). |
| `ConnectExchange` | Connects to Exchange Online (`Connect-ExchangeOnline`). |
| `ConnectPurview` | Connects to Purview / Security & Compliance via `Connect-IPPSSession -EnableSearchOnlySession`. |
| `ConnectTeams` | Connects to Microsoft Teams (`Connect-MicrosoftTeams`). |
| `ConnectSharePoint` | Connects to the SharePoint Online admin service. Builds the admin URL as `https://<domain-prefix>-admin.sharepoint.com` from the tenant's `PrimaryDomain`. |
| `ConnectAzure` | Connects to Azure via `Connect-AzAccount` (Az.Accounts). |
| `ConnectIntune` | Also triggers the Graph connection block (Intune operations ride on the same Graph session — there is no separate Intune-specific connect step). |
| `UseAppOnly` | Forces certificate-based app-only Graph auth instead of delegated interactive scopes, using the tenant's `AppRegistration.ClientId` / `CertificateThumbprint`. Also auto-enabled if the tenant config's `AppRegistration.UseAppOnly` is `true`. |
| `GraphScopes` | Delegated Graph scopes requested at interactive sign-in. Defaults to a broad set: `User.Read.All`, `Directory.ReadWrite.All`, `Group.ReadWrite.All`, `AuditLog.Read.All`, `Device.ReadWrite.All`, `Organization.Read.All`, `Mail.ReadWrite`, `Mail.ReadWrite.Shared`. Ignored when app-only auth is used. |

### Configuration block (top of script, after `param()`)
| Variable | Default | Purpose |
|---|---|---|
| `$script:ExchangeOnlineManagementMinVersion` | `3.9.0` | Minimum `ExchangeOnlineManagement` module version enforced via `Ensure-ModuleInstalled` when `-ConnectExchange` or `-ConnectPurview` is used. |
| `$script:GraphRequestMaxRetry` | `5` | Passed to `Set-MgRequestContext -MaxRetry` — Graph SDK v1.x only (see gotcha below). |
| `$script:GraphRequestRetryDelaySeconds` | `10` | Passed to `Set-MgRequestContext -RetryDelay` — Graph SDK v1.x only. |
| `$script:GraphApiProfile` | `v1.0` | Passed to `Select-MgProfile -Name` — Graph SDK v1.x only. |

### Prerequisites
- PowerShell modules, auto-installed on demand via `Ensure-ModuleInstalled` (from `Common.ps1`) depending on which `-Connect*` switches are used:
  - `Microsoft.Graph.Authentication` — always ensured (used whenever `-ConnectGraph` or `-ConnectIntune` is passed).
  - `ExchangeOnlineManagement` (minimum `3.9.0`) — for `-ConnectExchange` / `-ConnectPurview`.
  - `MicrosoftTeams` — for `-ConnectTeams`.
  - `Microsoft.Online.SharePoint.PowerShell` — for `-ConnectSharePoint`.
  - `Az.Accounts` — for `-ConnectAzure`.
- A matching entry for `-TenantName` in `config\tenants.json`, including `TenantId`, `PrimaryDomain`, `ExchangeOrganization`, and (for app-only auth) `AppRegistration.ClientId` / `AppRegistration.CertificateThumbprint`.
- For app-only/certificate auth, the certificate referenced by `AppRegistration.CertificateThumbprint` must be installed in the local certificate store used by `Connect-MgGraph`.

### Usage
```powershell
# Interactive Graph + Exchange Online for a hybrid tenant
. (Join-Path $PSScriptRoot 'core\Connect-M365.ps1') -TenantName 'Tenant-Example-NA' -ConnectGraph -ConnectExchange

# Graph only, app-only (certificate) auth, for an unattended/scheduled run
. .\core\Connect-M365.ps1 -TenantName 'Tenant-Example-Cloud' -ConnectGraph -UseAppOnly

# Full multi-workload connect for a bulk Teams + SharePoint report
. .\core\Connect-M365.ps1 -TenantName 'Tenant-Example-NA' -ConnectGraph -ConnectTeams -ConnectSharePoint

# Intune-only work rides on the Graph connection
. .\core\Connect-M365.ps1 -TenantName 'Tenant-Example-Cloud' -ConnectIntune

# Purview/eDiscovery + Exchange for a compliance search
. .\core\Connect-M365.ps1 -TenantName 'Tenant-Example-NA' -ConnectExchange -ConnectPurview

# Azure Automation / Az.Accounts based task
. .\core\Connect-M365.ps1 -TenantName 'Tenant-Example-Cloud' -ConnectAzure

# Custom delegated Graph scopes
. .\core\Connect-M365.ps1 -TenantName 'Tenant-Example-NA' -ConnectGraph -GraphScopes 'User.Read.All','Group.Read.All'
```

### Known gotchas
- There is a `TODO` in the file itself covering Graph SDK v1/v2 compatibility:
  > `Set-MgRequestContext` and `Select-MgProfile` were both removed from the Microsoft.Graph PowerShell SDK v2.x (profile selection is automatic in v2+, and retry/backoff configuration moved to `Connect-MgGraph` / module-level settings). These calls are wrapped in try/catch so this script does not hard-fail on newer SDK installs where the cmdlets no longer exist. Revisit once the toolbox standardizes on SDK v2.

  In practice: if you're on Graph SDK v2+, both calls will fail, be caught, and log a `WARN` line (`... not available (likely Graph SDK v2+)...`) — this is expected and non-fatal, not a sign of a broken connection. The `$script:GraphRequestMaxRetry`, `$script:GraphRequestRetryDelaySeconds`, and `$script:GraphApiProfile` config values are effectively no-ops on SDK v2+.
- `-ConnectSharePoint` derives the admin site URL from the first label of `PrimaryDomain` (e.g. `contoso.com` → `https://contoso-admin.sharepoint.com`). If a tenant's SharePoint admin URL doesn't follow that convention, `-ConnectSharePoint` will fail.
- Graph connections are unconditionally torn down first (`Disconnect-MgGraph -ErrorAction SilentlyContinue`) before reconnecting whenever `-ConnectGraph`/`-ConnectIntune` is used — there is no "already connected, skip" detection like some other toolkits use, so re-running this against the same tenant in the same session always reconnects.

---

## ErrorHandling.ps1

### What it does
Dot-sources `Common.ps1` and defines `Invoke-ToolboxSafely`, a standardized wrapper for running a scriptblock with consistent logging: it runs the block, logs `SUCCESS` via `Write-ToolboxLog` if it completes, logs `ERROR` (with the exception message) if it throws, and always clears `$Error` in a `finally` block so later operations start from a clean error state.

### Parameters
| Parameter | Notes |
|---|---|
| `ScriptBlock` | Mandatory. The code to execute. |
| `TenantName` | Used only for log line context. Defaults to `GLOBAL`. |
| `Operation` | Friendly operation name used in the log message. Defaults to `UnnamedOperation`. |
| `Rethrow` | If specified, re-throws the caught exception after logging it (so callers can still catch/stop on failure). Without it, the error is logged and swallowed. |

### Usage
```powershell
. (Join-Path $PSScriptRoot 'core\ErrorHandling.ps1')

Invoke-ToolboxSafely -Operation 'Get-Mailboxes' -TenantName 'Tenant-Example-NA' -ScriptBlock {
    Get-Mailbox -ResultSize Unlimited
}

# Propagate the failure to the caller after logging it
Invoke-ToolboxSafely -Operation 'Disable-MgUser' -TenantName 'Tenant-Example-Cloud' -Rethrow -ScriptBlock {
    Update-MgUser -UserId 'jdoe@contoso.com' -AccountEnabled:$false
}
```

### Known gotchas
- Without `-Rethrow`, a failure inside the scriptblock is logged but otherwise silent to the caller — the function returns normally. Callers that need to branch on success/failure should pass `-Rethrow` and catch it themselves, or check `$Error` before the `finally` clears it.

---

## Logging.ps1

### What it does
Dot-sources `Common.ps1` and provides transcript helpers built on PowerShell's native `Start-Transcript` / `Stop-Transcript`:
- `Start-ToolboxTranscript` — starts a transcript under `logs\transcripts\<Prefix>_<TenantName>_<yyyyMMddHHmmss>.txt` (creating the folder if needed) and returns the transcript's full path.
- `Stop-ToolboxTranscript` — stops the active transcript, swallowing any error if none is active (so it's always safe to call).

### Parameters
| Parameter | Notes |
|---|---|
| `TenantName` (Start-ToolboxTranscript) | Used in the transcript filename. Defaults to `GLOBAL`. |
| `Prefix` (Start-ToolboxTranscript) | Used in the transcript filename, typically the calling script's purpose (e.g. `Onboarding`). Defaults to `Session`. |

`Stop-ToolboxTranscript` takes no parameters.

### Usage
```powershell
. (Join-Path $PSScriptRoot 'core\Logging.ps1')

$transcriptPath = Start-ToolboxTranscript -TenantName 'Tenant-Example-NA' -Prefix 'Onboarding'
# ... do work ...
Stop-ToolboxTranscript
Write-Host "Full transcript saved to $transcriptPath"
```

---

## Retry.ps1

### What it does
Dot-sources `Common.ps1` and provides `Invoke-WithRetry`, a general-purpose retry-with-exponential-backoff wrapper. On failure it computes a delay of `BaseDelaySeconds * 2^(attempt-1)`, capped at `$script:RetryMaxDelaySeconds`. If the caught error looks like throttling (message matches `429`, `Too Many Requests`, or contains `throttl`), it logs a `WARN` specifically calling out throttling and waits the computed backoff delay; other errors are logged as a generic failure and retried after a flat `BaseDelaySeconds` delay instead of the exponential one. The last attempt's exception is re-thrown if all attempts are exhausted.

### Parameters
| Parameter | Notes |
|---|---|
| `ScriptBlock` | Mandatory. The code to execute/retry. Its return value is passed through on success. |
| `MaxAttempts` | Maximum number of attempts before giving up and re-throwing. Default `5`. |
| `BaseDelaySeconds` | Base delay used both for the flat non-throttle retry wait and as the base of the exponential throttle backoff. Default `5`. |
| `TenantName` | Used only for log line context. Defaults to `GLOBAL`. |
| `Operation` | Friendly operation name used in log messages. Defaults to `RetryOperation`. |

### Configuration block (top of script, after the synopsis)
| Variable | Default | Purpose |
|---|---|---|
| `$script:RetryMaxDelaySeconds` | `60` | Upper bound (seconds) on the exponential backoff delay, regardless of attempt count or `BaseDelaySeconds`. |

### Usage
```powershell
. (Join-Path $PSScriptRoot 'core\Retry.ps1')

$users = Invoke-WithRetry -Operation 'Get-MgUser' -TenantName 'Tenant-Example-NA' -ScriptBlock {
    Get-MgUser -All
}

# Tighter attempts / longer base delay for a known-flaky call
Invoke-WithRetry -Operation 'New-ComplianceSearch' -MaxAttempts 3 -BaseDelaySeconds 15 -ScriptBlock {
    New-ComplianceSearch -Name 'Search1' -ExchangeLocation All
}
```

### Known gotchas
- Only throttling-style errors get true exponential backoff; all other errors retry on a flat `BaseDelaySeconds` delay every attempt (not exponential) — this is intentional per the current code, but easy to misread as "everything backs off exponentially."

---

## Secrets.ps1

### What it does
Dot-sources `Common.ps1` and wraps `Microsoft.PowerShell.SecretManagement` / `Microsoft.PowerShell.SecretStore` for storing/retrieving toolbox secrets (e.g. client secrets, service account credentials) without hardcoding them in scripts or config:
- `Ensure-SecretModules` — ensures both `Microsoft.PowerShell.SecretManagement` and `Microsoft.PowerShell.SecretStore` are installed (via `Ensure-ModuleInstalled`).
- `Initialize-ToolboxSecretStore` — calls `Ensure-SecretModules`, then registers the toolbox's default `SecretStore`-backed vault (named per the config value below) if it isn't already registered.
- `Set-ToolboxSecret` — initializes the store, then writes a secret into the toolbox vault.
- `Get-ToolboxSecret` — initializes the store, then reads a secret back out of the toolbox vault.

### Parameters
| Parameter | Notes |
|---|---|
| `Name` (Set-ToolboxSecret / Get-ToolboxSecret) | Mandatory. The secret's name/key in the vault. |
| `Secret` (Set-ToolboxSecret) | Mandatory. The secret value to store (e.g. a `SecureString` or credential object). |

`Ensure-SecretModules` and `Initialize-ToolboxSecretStore` take no parameters.

### Configuration block (top of script, after the synopsis)
| Variable | Default | Purpose |
|---|---|---|
| `$script:ToolboxSecretVaultName` | `ToolboxSecretStore` | Name of the `SecretManagement` vault registered/used for all toolbox secrets. |

### Prerequisites
- `Microsoft.PowerShell.SecretManagement` and `Microsoft.PowerShell.SecretStore` modules (auto-installed via `Ensure-ModuleInstalled` on first use).
- The `SecretStore` vault must be unlocked/accessible in the context the script runs under — on an unattended/scheduled task this typically means configuring a non-interactive `SecretStore` password or vault unlock policy ahead of time; this file does not configure that for you.

### Usage
```powershell
. (Join-Path $PSScriptRoot 'core\Secrets.ps1')

$secureSecret = Read-Host -AsSecureString -Prompt 'Enter app client secret'
Set-ToolboxSecret -Name 'Tenant-Example-NA-ClientSecret' -Secret $secureSecret

$secret = Get-ToolboxSecret -Name 'Tenant-Example-NA-ClientSecret'
```

---

## CodeSigning.ps1

### What it does
Dot-sources `Common.ps1` and provides `Sign-ToolboxScripts`, which locates a code-signing certificate by thumbprint in `Cert:\CurrentUser\My` and uses `Set-AuthenticodeSignature` to sign every matching script file recursively under a root path (defaulting to the toolbox root). Each file's resulting signature status is checked against an accepted-status list; anything not acceptable is collected as a failure and logged as an `ERROR`, and if any failures occurred the function throws a summary error listing every failed file at the end (rather than failing silently or stopping at the first bad file).

### Parameters
| Parameter | Notes |
|---|---|
| `CertificateThumbprint` | Mandatory. Thumbprint of the code-signing certificate, looked up in `Cert:\CurrentUser\My`. Throws if not found. |
| `TimestampServer` | RFC3161 timestamp server URL used when signing. Defaults to `http://timestamp.sectigo.com`. |
| `RootPath` | Root folder to recursively sign scripts under. Defaults to the toolbox root (via `Get-ToolboxRoot`) when omitted. |

### Configuration block (top of script, after the synopsis)
| Variable | Default | Purpose |
|---|---|---|
| `$script:ToolboxSignableExtensions` | `@('*.ps1', '*.psm1')` | File extension glob patterns included when recursively signing. |
| `$script:AcceptableSignatureStatuses` | `@('Valid')` | Signature status values (from `Set-AuthenticodeSignature`'s return object) treated as success; anything else is recorded as a failure. |

### Prerequisites
- A code-signing certificate with a private key installed in `Cert:\CurrentUser\My` on the machine running the sign operation.
- Network access to the configured `-TimestampServer` (or override it if your signing certificate's CA recommends a different RFC3161 endpoint).

### Usage
```powershell
. (Join-Path $PSScriptRoot 'core\CodeSigning.ps1')

# Sign every .ps1/.psm1 under the toolbox root
Sign-ToolboxScripts -CertificateThumbprint 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'

# Sign only a specific subfolder, with a custom timestamp server
Sign-ToolboxScripts -CertificateThumbprint 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' `
    -RootPath 'C:\Toolbox\bulk' -TimestampServer 'http://timestamp.digicert.com'
```

### Known gotchas
- The function throws only after attempting to sign every discovered file — check the thrown exception's message (or the log) for the full list of failed files rather than assuming the first error is the only one.

---

## Prerequisites (all of core\)

The following PowerShell modules are used across `core\`, all installed on demand via `Ensure-ModuleInstalled` (defined in `Common.ps1`) rather than requiring manual pre-installation:
- `Microsoft.Graph.Authentication`
- `ExchangeOnlineManagement`
- `MicrosoftTeams`
- `Microsoft.Online.SharePoint.PowerShell`
- `Az.Accounts`
- `Microsoft.PowerShell.SecretManagement`
- `Microsoft.PowerShell.SecretStore`

A valid `config\tenants.json` (see the toolbox root `config\` folder) is required for any script that calls `Get-TenantConfig` or `Connect-M365.ps1`, since tenant name, tenant ID, domain, Exchange organization, and app registration details are all sourced from it.
