# User lifecycle scripts

## New-UserLifecycle.ps1
Creates a user in Microsoft 365 using Graph, assigns licenses, and adds group memberships.

### Workflow
1. Loads the connector with Graph.
2. Pulls tenant defaults from JSON.
3. Creates the user.
4. Resolves SKU part numbers to SKU IDs.
5. Assigns licenses.
6. Adds default and explicit groups.
7. Returns the temporary password.

### Hybrid note
If `HybridCreateOnPremFirst` is used and the tenant is hybrid, the script records that the on-prem user creation workflow should occur first.

## Disable-UserLifecycle.ps1
Handles user offboarding controls.

### Optional actions
- Disable sign-in
- Revoke sessions
- Remove licenses
- Convert mailbox to shared
- Disable Entra devices
- Trigger on-prem disabled OU handling


## Bulk onboarding
Use `bulk\Invoke-BulkUserOnboarding.ps1` with `templates\BulkUserOnboarding.csv` to process many users across many tenants.

## Bulk offboarding
Use `bulk\Invoke-BulkUserOffboarding.ps1` with `templates\BulkUserOffboarding.csv` to process many offboarding events across many tenants.
