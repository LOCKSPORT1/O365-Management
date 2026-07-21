# 01-Onboarding

Two scripts that work together to take a new hire from "nothing exists" to
"licensed, grouped, and ready to sign in."

---

## New-M365UserOnboarding.ps1

### What it does
Creates the user account, either:
- **CloudOnly** — directly in Entra ID via Graph, or
- **HybridSync** — in on-prem AD in the right OU, then triggers an Entra
  Connect delta sync (via `Invoke-Command` to your AAD Connect server) and
  waits for the object to appear in Entra ID.

Once the account exists in Entra ID, it automatically calls
`Add-UserToGroupsAndLicenses.ps1` to finish licensing/groups.

### Parameters
| Parameter | Required | Notes |
|---|---|---|
| `FirstName` / `LastName` | Yes | Used to build display name, UPN, mailNickname |
| `JobTitle` | Yes | Written to the AD/Entra job title attribute |
| `Department` | Yes | Drives license + group mapping (see script #2) |
| `ManagerUpn` | Yes | UPN of the new hire's manager |
| `Mode` | No (default `HybridSync`) | `CloudOnly` or `HybridSync` |

### Parameters
| Parameter | Required | Notes |
|---|---|---|
| `FirstName` / `LastName` | Yes | Used to build display name, UPN, mailNickname |
| `JobTitle` | Yes | Written to the AD/Entra job title attribute |
| `Department` | Yes | Drives license + group mapping (see script #2) |
| `ManagerUpn` | Yes | UPN of the new hire's manager |
| `Mode` | No (default `HybridSync`) | `CloudOnly` or `HybridSync` |
| `AuthMode` | No (default `Interactive`) | `Interactive`, `AppSecret`, or `Certificate` — passed through to `Assert-M365Connection` |

### CONFIGURATION block (`$Config`)
Located near the top of the script, right after the `param()` block, under a
`CONFIGURATION - adjust these values for your environment` banner. Edit these
before running against your tenant:

| Variable | Purpose |
|---|---|
| `UsageLocation` | ISO country code, required before licensing works |
| `Domain` | Domain used to build the UPN |
| `DefaultPasswordLength` | Temp password length |
| `ForcePasswordChangeOnLogin` | Forces password reset at first sign-in |
| `ADTargetOU` | Distinguished name of the OU new accounts land in (HybridSync only) |
| `ADServer` | DC to target for AD cmdlets (HybridSync only) |
| `EntraConnectSyncCommand` | Command run remotely to force a delta sync (HybridSync only) |
| `EntraConnectServer` | Hostname of your AAD Connect server (HybridSync only) |
| `SyncWaitSeconds` | Seconds to wait after triggering a delta sync before checking Entra ID (HybridSync only) |
| `BaselineGroups` | Groups every new hire gets regardless of department |

### Prerequisites
- PowerShell module `Microsoft.Graph` (Users, Groups, Users.Actions sub-modules).
- `ActiveDirectory` module (HybridSync mode) — run this on/near a DC, or a
  host with RSAT tools and line of sight to `$ADServer`.
- WinRM/`Invoke-Command` access to `$EntraConnectServer` (HybridSync mode).
- Graph permissions: `User.ReadWrite.All`, `Directory.ReadWrite.All` (create
  users, set manager) at minimum — see `00-Setup\Connect-M365Services.ps1`
  for the full delegated/app scope list.
- Graph connected via `Connect-M365Services.ps1` before running — this
  script self-connects automatically via `Assert-M365Connection` if not
  already connected.

### Usage
```powershell
.\New-M365UserOnboarding.ps1 -FirstName "Jane" -LastName "Doe" `
    -JobTitle "Sales Associate" -Department "Sales" `
    -ManagerUpn "john.smith@yourdomain.com" -Mode HybridSync

# Cloud-only account, app-only auth (e.g. from a scheduled task)
.\New-M365UserOnboarding.ps1 -FirstName "Jane" -LastName "Doe" `
    -JobTitle "Sales Associate" -Department "Sales" `
    -ManagerUpn "john.smith@yourdomain.com" -Mode CloudOnly -AuthMode AppSecret
```

### Known gotchas
- Entra Connect delta sync can take longer than the `SyncWaitSeconds`
  (default 90s) built-in wait during busy sync windows. If the script warns
  that the user isn't visible yet, just re-run
  `Add-UserToGroupsAndLicenses.ps1` manually a few minutes later.
- `SamAccountName` is truncated to 20 characters for AD compatibility;
  double check it didn't collide with an existing account.
- User/AD account creation and the Entra Connect sync trigger are now
  wrapped in try/catch — a failure during account creation stops the
  script before it attempts manager/license/group assignment on a
  nonexistent user.

---

## Add-UserToGroupsAndLicenses.ps1

### What it does
Sets `UsageLocation`, then assigns license SKUs and security group
memberships based on a Department lookup table. Designed to run standalone
too — useful for correcting a mis-licensed existing user.

### Parameters
| Parameter | Required | Notes |
|---|---|---|
| `UserId` | Yes | Entra ID object ID or UPN of the user to license/group |
| `Department` | Yes | Looked up in `$DepartmentLicenseMap` / `$DepartmentGroupMap`; falls back to `"Default"` if no match |
| `AdditionalGroups` | No (default none) | Extra group display names added on top of the department mapping |
| `UsageLocation` | No (default `"US"`) | ISO country code set before license assignment |
| `AuthMode` | No (default `Interactive`) | `Interactive`, `AppSecret`, or `Certificate` — passed through to `Assert-M365Connection` |

### CONFIGURATION block
Located near the top of the script, right after the `param()` block, under a
`CONFIGURATION - adjust these values for your environment` banner:
- `$DepartmentLicenseMap` — Department -> array of SKU part numbers, plus a
  `"Default"` fallback entry. **You must edit this to match your tenant's
  actual SKUs.** Run `Get-MgSubscribedSku | Select SkuPartNumber, SkuId` to
  find yours.
- `$DepartmentGroupMap` — Department -> array of security group display
  names, plus a `"Default"` fallback entry.

### Prerequisites
- PowerShell module `Microsoft.Graph` (Users, Groups, Users.Actions sub-modules).
- Graph permissions: `User.ReadWrite.All`, `Group.ReadWrite.All`,
  `Directory.ReadWrite.All` — see `00-Setup\Connect-M365Services.ps1` for
  the full scope list.
- Graph connected via `Connect-M365Services.ps1` before running — this
  script self-connects automatically via `Assert-M365Connection` if not
  already connected.

### Usage (standalone)
```powershell
.\Add-UserToGroupsAndLicenses.ps1 -UserId "jane.doe@yourdomain.com" -Department "Engineering"

# With extra baseline groups and a non-default usage location
.\Add-UserToGroupsAndLicenses.ps1 -UserId "jane.doe@yourdomain.com" -Department "Sales" `
    -AdditionalGroups "SG-AllStaff","SG-VPN-Users" -UsageLocation "GB"
```

### Known gotchas
- If a SKU has 0 available seats, the script warns and skips rather than
  failing the whole run — check the yellow warnings after every batch.
- Group add failures for "already a member" are caught and downgraded to
  informational — safe to re-run.
- Usage location and license assignment failures are now caught individually
  and reported as warnings rather than throwing — one bad SKU or a transient
  Graph error won't abort the rest of the run.
