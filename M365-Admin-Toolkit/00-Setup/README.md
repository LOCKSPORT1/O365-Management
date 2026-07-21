# 00-Setup — Connect-M365Services.ps1

## What it does
Central authentication helper. **Every other script in this toolkit calls
this automatically** — you don't need to dot-source or connect anything
yourself before running a script. This file defines three functions:

- `Connect-M365 -Services Graph,ExchangeOnline -AuthMode Interactive|AppSecret|Certificate`
  — does the actual connecting.
- `Assert-M365Connection -Services Graph -AuthMode Interactive`
  — **this is the one every other script calls.** Checks whether the
  required session(s) are already live and only calls `Connect-M365` if
  they aren't, so re-running scripts in the same session doesn't
  reconnect redundantly, and running a script standalone still works
  without any manual setup step.
- `Disconnect-M365` — tears down both sessions cleanly, if you want to.

### How the self-connecting pattern works
Every other script in this toolkit has, right after its `param()` block:
```powershell
#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion
```
`$AuthMode` is a parameter every script exposes, defaulting to
`Interactive`. This means every script is self-sufficient — you can run
any single one on its own, in any order, and it'll connect what it needs
and skip reconnecting if you're already signed in from a prior script in
the same session.

**Detection caveat:** Graph connection detection (`Get-MgContext`) is
reliable. Exchange Online / Compliance Center detection uses
`Get-ConnectionInformation` and inspects the connection URI — reliable on
current module versions, but if you're on an older `ExchangeOnlineManagement`
version and it misfires (connects when you're already connected, or vice
versa), pass `-Force` to `Assert-M365Connection` to skip detection and
always reconnect.

**Error handling:** `Connect-M365` wraps each service's connection attempt
(Graph, Exchange Online, Compliance Center) in its own try/catch. If a
connection fails (bad thumbprint, wrong `-Organization` value, expired
secret, etc.) it throws a clear error naming the service and `AuthMode`
instead of failing silently or with a cryptic SDK error.

## Functions / parameters exposed
- `Connect-M365 -Services <Graph,ExchangeOnline,ComplianceCenter> -AuthMode <Interactive|AppSecret|Certificate>`
- `Assert-M365Connection -Services <...> -AuthMode <...> [-Force]`
  — `-Force` skips the live-session check and always (re)connects.
- `Disconnect-M365` — no parameters; tears down Graph, Exchange Online, and
  Compliance Center sessions (the latter two share one underlying session).

## Configuration block (`$Global:M365Config`)
All adjustable values live in one clearly labeled `CONFIGURATION` block near
the top of `Connect-M365Services.ps1`, right after the comment-based help:

| Variable | Purpose | Required for |
|---|---|---|
| `TenantId` | Your tenant GUID or `.onmicrosoft.com` domain — passed to Graph's `-TenantId` | All auth modes (Graph) |
| `OrganizationDomain` | Your tenant's verified `.onmicrosoft.com` domain — passed to `-Organization` on `Connect-ExchangeOnline`/`Connect-IPPSSession` | AppSecret / Certificate modes (Exchange Online / Compliance Center) |
| `ClientId` | App registration (client) ID | AppSecret / Certificate modes |
| `CertThumbprint` | Thumbprint of cert used for unattended auth | Certificate mode |
| `ClientSecret` | Client secret string | AppSecret mode (not recommended — see below) |
| `GraphScopes` | Array of delegated Graph scopes requested at interactive sign-in | Interactive mode |

**Why `TenantId` and `OrganizationDomain` are separate:** Graph's
`-TenantId` parameter accepts either a tenant GUID or the
`.onmicrosoft.com` domain, but Exchange Online / Security & Compliance
Center's `-Organization` parameter for app-only auth **requires the
verified domain name — a tenant GUID will fail there.** Keeping these as
two distinct config values avoids a subtle auth failure if your `TenantId`
is set to a GUID.

## Prerequisites
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
```
Use PowerShell 7 (`pwsh.exe`), not 5.1 — EXO session stability on 5.1 is
noticeably worse, especially for long-running or looped operations.

## App registration permissions (for AppSecret/Certificate modes)
Grant these as **Application** permissions (admin consent required):
- `User.ReadWrite.All`
- `Group.ReadWrite.All`
- `Directory.ReadWrite.All`
- `DeviceManagementManagedDevices.ReadWrite.All`
- `DeviceManagementServiceConfig.ReadWrite.All`
- `Organization.Read.All`
- For Exchange Online app-only auth, also assign the app the
  `Exchange Administrator` role (or a scoped custom role) and register a
  certificate under **API permissions > Certificates & secrets**.

## Security note
Don't hardcode `ClientSecret` in plaintext for anything that runs
unattended (scheduled tasks, NinjaRMM scripts). Prefer certificate auth, or
pull the secret at runtime from a secret store (Azure Key Vault, or even
just an encrypted credential file via `Export-Clixml` scoped to the service
account that runs the task).

## Usage
You don't need to do this manually anymore — every script calls
`Assert-M365Connection` on its own. This is only here if you want to
pre-connect before running several scripts back-to-back, or for
interactive/exploratory work outside the toolkit's scripts:
```powershell
. .\00-Setup\Connect-M365Services.ps1
Connect-M365 -Services Graph,ExchangeOnline -AuthMode Interactive
# ... do work ...
Disconnect-M365
```
