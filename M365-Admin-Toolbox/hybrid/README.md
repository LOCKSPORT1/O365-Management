# hybrid

Scripts for tenants that run hybrid identity (on-prem Active Directory synchronized to
Microsoft Entra ID via Entra Connect / AAD Connect). These cover creating and disabling
on-prem AD accounts, triggering a directory sync cycle, and the shared PowerShell
remoting helper the other scripts use to reach the on-prem environment.

There is no pre-existing `docs\README-Hybrid.md` for this folder — this README was
written directly from the script source.

**UPN domain is automatic.** `New-HybridADUser.ps1` accepts `-UserPrincipalName` as either a
full address (`jdoe@corp.contoso.com`) or just the local part (`jdoe`). If no `@` is present,
`Resolve-ToolboxUserPrincipalName` (in `core\Common.ps1`) appends the tenant's `PrimaryDomain`
from `config\tenants.json` automatically, so the on-prem AD account and the cloud account it
syncs to always end up on the same, correct domain without anyone typing it twice.

---

## How it fits together

Every script here resolves its on-prem connection details from the tenant's `OnPrem`
block in `config\tenants.json`:

```json
"OnPrem": {
  "Enabled": true,
  "DomainFqdn": "corp.contoso.com",
  "OUPathUsers": "OU=Users,DC=corp,DC=contoso,DC=com",
  "OUPathDisabledUsers": "OU=Disabled Users,DC=corp,DC=contoso,DC=com",
  "RemoteHost": "dc01.corp.contoso.com",
  "SyncAuthority": "OnPremAD"
}
```

`Invoke-OnPremSession.ps1` is the shared helper: it reads `OnPrem.RemoteHost`, refuses to
run if `OnPrem.Enabled` is `false` or `RemoteHost` is blank, opens a `New-PSSession` to
that host (retrying transient failures), runs the caller's script block there via
`Invoke-Command`, and always tears the session down in a `finally` block.
`Disable-HybridADUser.ps1`, `New-HybridADUser.ps1`, and `Start-ADSync.ps1` all dot-source
it rather than opening their own sessions.

No script hardcodes a domain, OU path, or hostname — all of that comes from tenant
config. Examples below use the `corp.contoso.com` / `Tenant-Example-NA` placeholder
style from `config\tenants.json`.

---

## Prerequisites

- PowerShell 7+ (or Windows PowerShell 5.1) with WinRM/PowerShell remoting enabled
  between the machine running these scripts and the tenant's on-prem `OnPrem.RemoteHost`.
- The `ActiveDirectory` PowerShell module installed **on the remote host** (imported
  inside the remote script block, not locally).
- The `ADSync` module installed on the Entra Connect / AAD Connect server itself —
  `Start-ADSync.ps1` must target a host that is actually running the sync service.
- An account with rights to create/disable/move AD objects in the target OU(s), and
  rights to trigger sync cycles on the Entra Connect server. By default, remoting uses
  the current user's Kerberos/WinRM trust; pass `-Credential` to `Invoke-OnPremSession.ps1`
  (or to the calling script, if it exposes the parameter) to use alternate credentials.
  **Credentials are never hardcoded** — supply a `PSCredential` via `Get-Credential` or a
  secure credential store.

---

## Scripts

### Invoke-OnPremSession.ps1

Shared helper, not usually called directly. Opens a PSSession to the tenant's
`OnPrem.RemoteHost`, executes a supplied script block remotely, and cleans up. Centralizes
session retry logic and error logging so the other hybrid scripts don't duplicate it.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. Resolves `OnPrem.RemoteHost` and confirms `OnPrem.Enabled`. |
| `ScriptBlock` | Mandatory. Code to run on the remote host; declare a `param()` block matching `-ArgumentList`. |
| `ArgumentList` | Positional arguments passed through to the remote script block. |
| `Credential` | Optional `PSCredential` for the remote connection. Omit to use current-user trust. |

**Configuration block:** `$SessionRetryAttempts` (3), `$SessionRetryDelaySeconds` (5).

**Example**
```powershell
. (Join-Path $PSScriptRoot 'Invoke-OnPremSession.ps1') -TenantName 'Tenant-Example-NA' -ScriptBlock {
    param($Name)
    Get-ADUser -Identity $Name
} -ArgumentList @('jdoe')
```

---

### New-HybridADUser.ps1

Creates a new on-prem AD user in the tenant's configured users OU
(`OnPrem.OUPathUsers`), optionally adding it to one or more on-prem groups. Run
`Start-ADSync.ps1` afterward to push the new account to Entra ID.

No default password is hardcoded: if `-InitialPassword` is omitted, a random password is
generated (length controlled by config) and logged once so it can be relayed securely;
the account is always created with `ChangePasswordAtLogon = $true`.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `SamAccountName` | Mandatory. |
| `UserPrincipalName` | Mandatory. |
| `DisplayName` / `GivenName` / `Surname` | Mandatory. |
| `Department` / `JobTitle` / `OfficeLocation` | Optional attributes. |
| `InitialPassword` | Optional; auto-generated if omitted. |
| `OnPremGroups` | Optional array of on-prem group names/DNs to add the user to. |

**Configuration block:** `$GeneratedPasswordLength` (16).

**Example**
```powershell
.\New-HybridADUser.ps1 -TenantName 'Tenant-Example-NA' -SamAccountName 'jdoe' `
    -UserPrincipalName 'jdoe@corp.contoso.com' -DisplayName 'Jane Doe' `
    -GivenName 'Jane' -Surname 'Doe' -Department 'Finance' -OnPremGroups @('Finance-Team')
```

---

### Disable-HybridADUser.ps1

Disables an on-prem AD account for a hybrid (on-prem source-of-authority) user.
Optionally strips all non-default group memberships (best-effort — a failure removing
one group is logged and does not stop the rest) and/or moves the account to the tenant's
configured `OnPrem.OUPathDisabledUsers`.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `SamAccountName` | Mandatory. |
| `MoveToDisabledOU` | Moves the account to `OnPrem.OUPathDisabledUsers` after disabling. |
| `RemoveFromAllNonDefaultGroups` | Removes the account from every group in its `MemberOf`. |

**Example**
```powershell
.\Disable-HybridADUser.ps1 -TenantName 'Tenant-Example-NA' -SamAccountName 'jdoe' `
    -MoveToDisabledOU -RemoveFromAllNonDefaultGroups
```

---

### Start-ADSync.ps1

Triggers an Entra Connect / AAD Connect sync cycle (`Start-ADSyncSyncCycle`) on the
tenant's configured sync server. Retries automatically if a sync cycle is already in
progress (a common transient condition).

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `PolicyType` | `Delta` (default, incremental) or `Initial` (full sync). |

**Configuration block:** `$SyncRetryAttempts` (3), `$SyncRetryBaseDelaySeconds` (15).

**Example**
```powershell
.\Start-ADSync.ps1 -TenantName 'Tenant-Example-NA'
.\Start-ADSync.ps1 -TenantName 'Tenant-Example-NA' -PolicyType 'Initial'
```

---

## Known gotchas

- `Start-ADSync.ps1` will fail unless `OnPrem.RemoteHost` for the tenant actually points
  at the box running the Entra Connect `ADSync` service — it is not necessarily the same
  host as a domain controller.
- Scripts throw early (before opening any remote session) if `OnPrem.Enabled` is `false`
  for the tenant, or if `OnPrem.RemoteHost` is blank — check `config\tenants.json` first
  if you get an "not configured for on-prem operations" error.
- After `New-HybridADUser.ps1` or `Disable-HybridADUser.ps1`, changes are not reflected in
  Entra ID until the next sync cycle completes — run `Start-ADSync.ps1` (or wait for the
  scheduled Delta cycle) if you need the change to show up in the cloud immediately.
