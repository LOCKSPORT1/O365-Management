# lifecycle

Single-user onboarding and offboarding orchestration for Microsoft 365 (Entra ID)
identities: create a user with licenses and group memberships, or disable a user with a
menu of opt-in offboarding actions. For hybrid tenants, these scripts coordinate with
(rather than duplicate) the on-prem AD scripts in `hybrid\`.

Both scripts take a mandatory `-TenantName` parameter, dot-source `..\core\Common.ps1`
and `..\core\Retry.ps1`, and connect via `..\core\Connect-M365.ps1`, which resolves
tenant details (default license SKUs, default groups, default usage location, on-prem
configuration) from `config\tenants.json`. No script hardcodes a tenant ID, domain,
company name, UPN, or OU path; examples use the `contoso.com` / `fabrikam.com` /
`Tenant-Example-NA` / `Tenant-Example-Cloud` placeholders from `config\tenants.json`.

**UPN domain is automatic.** `New-UserLifecycle.ps1` accepts `-UserPrincipalName` as either
a full address (`jdoe@contoso.com`) or just the local part (`jdoe`). If no `@` is present,
`Resolve-ToolboxUserPrincipalName` (in `core\Common.ps1`) appends the tenant's `PrimaryDomain`
from `config\tenants.json` automatically. This means an operator (or a bulk-onboarding CSV
row) never has to type or select the right domain by hand — it's pulled from config, so a new
user always lands on the correct verified domain. **Usage location is automatic too** — if
`-UsageLocation` isn't supplied, it defaults to the tenant's `Cloud.DefaultUsageLocation`
(e.g. `"US"`), which is required before Graph will allow a license assignment to succeed.

---

## Prerequisites

- PowerShell 7+ recommended.
- Microsoft Graph PowerShell SDK (`Microsoft.Graph.Users`,
  `Microsoft.Graph.Users.Actions`, `Microsoft.Graph.Identity.DirectoryManagement`).
- `ExchangeOnlineManagement` module — only needed by `Disable-UserLifecycle.ps1` when
  `-ConvertMailboxToShared` is used (mailbox conversion is an Exchange Online operation;
  Graph alone cannot do it).
- Graph permissions: `User.ReadWrite.All` (create/disable/update), `Group.ReadWrite.All`
  (group membership), `Organization.Read.All` (license SKU resolution via
  `Resolve-LicenseSkuIds`/`Get-MgSubscribedSku`), `Device.ReadWrite.All` (disabling
  registered devices).
- For hybrid tenants, an understanding that these scripts do **not** touch on-prem AD
  directly — see the Hybrid coordination section below.

---

## Scripts

### New-UserLifecycle.ps1

Creates a new Entra ID user via `New-MgUser`, resolves the requested (or tenant-default)
license SKU part numbers to SKU IDs via `Resolve-LicenseSkuIds`, assigns those licenses,
and adds the user to any explicit groups plus the tenant's default groups
(`Cloud.DefaultUserGroups`). Returns a `[pscustomobject]` with the UPN and a randomly
generated temporary password (cryptographically random via
`System.Security.Cryptography.RandomNumberGenerator`, not a fixed/weak default, and not
dependent on the `System.Web` assembly).

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `DisplayName` / `UserPrincipalName` / `MailNickname` | Mandatory. |
| `GivenName` / `Surname` / `Department` / `JobTitle` / `OfficeLocation` | Optional attributes. |
| `UsageLocation` | Optional; defaults to `Cloud.DefaultUsageLocation` from tenant config. |
| `LicenseSkuPartNumbers` | Optional array (e.g. `ENTERPRISEPACK`, `SPE_E5`); defaults to `Cloud.DefaultLicenseSkuPartNumbers`. |
| `GroupIds` | Optional array of group object IDs, added in addition to `Cloud.DefaultUserGroups`. |
| `HybridCreateOnPremFirst` | If the tenant is hybrid, logs a notice to create the on-prem account first via `hybrid\New-HybridADUser.ps1` and returns **without** creating a cloud user (prevents a duplicate/conflicting object). |

**Configuration block:** `$TempPasswordLength` (16), `$TempPasswordMinNonAlphanumeric`
(3), `$TempPasswordCharSet` (ambiguous characters like `O`/`0`, `I`/`l`/`1` excluded),
`$RetryMaxAttempts` (5), `$RetryBaseDelaySeconds` (5).

**Example**
```powershell
.\New-UserLifecycle.ps1 -TenantName 'Tenant-Example-Cloud' -DisplayName 'Jane Doe' `
    -UserPrincipalName 'jane.doe@fabrikam.com' -MailNickname 'jane.doe' -GivenName 'Jane' `
    -Surname 'Doe' -Department 'Sales'
```

**Hybrid note:** if the tenant's `OnPrem.Enabled` is `true` and `-HybridCreateOnPremFirst`
is passed, this script does not create a cloud user at all — create the on-prem account
first (`hybrid\New-HybridADUser.ps1`) and let Entra Connect sync create the cloud object.

---

### Disable-UserLifecycle.ps1

Disables sign-in (`Update-MgUser -AccountEnabled:$false`) for a user, then performs any
additional offboarding actions explicitly requested via switches — nothing beyond the
sign-in disable happens unless you opt in:

| Switch | Action |
|---|---|
| `RevokeSessions` | Revokes active sign-in sessions/refresh tokens (`Revoke-MgUserSignInSession`). |
| `RemoveLicenses` | Strips all currently assigned license SKUs (`Set-MgUserLicense`). |
| `ConvertMailboxToShared` | Converts the mailbox to shared via Exchange Online (`Set-Mailbox -Type Shared`); this switch also triggers an Exchange Online connection, which is otherwise skipped. |
| `DisableDevices` | Disables all Entra ID devices registered to the user. |
| `MoveOnPremObjectToDisabledOU` | For hybrid tenants, logs a notice that the on-prem AD object should be moved via `hybrid\Disable-HybridADUser.ps1`; warns (and skips) if the tenant isn't hybrid-enabled. |

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `UserPrincipalName` | Mandatory. |
| `ConvertMailboxToShared` / `RemoveLicenses` / `DisableDevices` / `RevokeSessions` / `MoveOnPremObjectToDisabledOU` | All optional, independently gated switches. |

**Configuration block:** `$RetryMaxAttempts` (5), `$RetryBaseDelaySeconds` (5).

**Example**
```powershell
.\Disable-UserLifecycle.ps1 -TenantName 'Tenant-Example-Cloud' -UserPrincipalName 'jane.doe@fabrikam.com' `
    -RevokeSessions -RemoveLicenses -ConvertMailboxToShared

.\Disable-UserLifecycle.ps1 -TenantName 'Tenant-Example-NA' -UserPrincipalName 'jane.doe@contoso.com' `
    -RevokeSessions -MoveOnPremObjectToDisabledOU
```

---

## Hybrid coordination

Neither lifecycle script touches on-prem Active Directory directly — they only log a
notice pointing at the matching `hybrid\` script:

- `New-UserLifecycle.ps1 -HybridCreateOnPremFirst` → run `hybrid\New-HybridADUser.ps1`
  first, then let Entra Connect sync create the cloud object.
- `Disable-UserLifecycle.ps1 -MoveOnPremObjectToDisabledOU` → run
  `hybrid\Disable-HybridADUser.ps1 -MoveToDisabledOU` to actually move the on-prem object.

This separation keeps the cloud-side and on-prem-side workflows independently testable
and avoids the lifecycle scripts silently attempting on-prem AD writes without a
PowerShell remoting session.

---

## Bulk operations

For processing many users across many tenants at once, see `bulk\Invoke-BulkUserOnboarding.ps1`
(with `templates\BulkUserOnboarding.csv`) and `bulk\Invoke-BulkUserOffboarding.ps1` (with
`templates\BulkUserOffboarding.csv`). These are outside the scope of this folder but wrap
the same `New-UserLifecycle.ps1` / `Disable-UserLifecycle.ps1` scripts per row.

## Related

- `docs\README-Lifecycle.md` — original short-form reference doc for this folder.
