# Intune Primary User Audit

**Find and fix Intune devices assigned to the wrong primary user — based on who actually logs in.**

## The problem

You enroll a laptop, image it, sign in to test it, and ship it to the new hire. Six months later, Intune still says *you* own it. Multiply that across every technician and every enrollment wave, and your fleet's ownership data quietly rots:

- Company Portal shows the wrong owner on the endpoint
- User-targeted app and policy assignments resolve to the wrong person
- Offboarding and asset reports can't be trusted

Manually cross-referencing sign-in activity against primary user assignments for hundreds of devices isn't realistic. This script does it in one run.

## How it works

1. Pulls all Intune-managed Windows devices via Microsoft Graph
2. Pulls all **successful interactive `Windows Sign In` events** from Entra sign-in logs for a lookback window (default 14 days, max 30)
3. Determines the most frequent interactive user per device
4. Flags a mismatch only when the evidence is strong — the top user must differ from the assigned primary user, **and** meet a minimum sign-in count (default 5), **and** account for a minimum share of the device's activity (default 60%). One-off support logons and borrowed laptops don't trigger false flags.
5. Writes a full CSV report; optionally reassigns the primary user via Graph

## Usage

```powershell
# Audit only — writes PrimaryUserAudit_<timestamp>.csv
.\Invoke-PrimaryUserAudit.ps1

# Interactive remediation — Y/N per device, A for all, Q to quit
.\Invoke-PrimaryUserAudit.ps1 -Fix

# Dry run
.\Invoke-PrimaryUserAudit.ps1 -Fix -WhatIf

# Unattended remediation with a 30-day window
.\Invoke-PrimaryUserAudit.ps1 -Fix -Force -LookbackDays 30
```

If your execution policy blocks it:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Invoke-PrimaryUserAudit.ps1"
```

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- `Microsoft.Graph.Authentication` module (auto-installs if missing)
- Entra ID P1/P2 (sign-in log retention)
- Delegated Graph scopes: `DeviceManagementManagedDevices.ReadWrite.All`, `AuditLog.Read.All`, `User.Read.All`, `Directory.Read.All`

## Configuration

Everything lives in the `#region Configuration` block:

- **`$ExcludedUserPatterns`** — add your technician/admin/service account UPNs so support logons never nominate IT staff as the "real" user
- **`$ExcludedDevicePatterns`** — skip kiosks and shared devices (those should usually have *no* primary user, not a reassigned one)
- **`$MinimumSignIns` / `$DominancePercent`** — tune flagging sensitivity

## Report columns worth knowing

- `Mismatch` — TRUE means flagged for correction
- `AllUsers` — every user seen on the device with sign-in counts; review this before fixing, since several heavy users usually means a genuinely shared machine
- `(no sign-ins in window)` — device was offline/stale during the window; not flagged

## Safety

- Audit mode is read-only
- Fix mode prompts per device by default; `-Force` is opt-in
- Supports `-WhatIf`
- Every run writes a CSV capturing the prior owner, so changes are traceable and reversible

## License

MIT — use it, fork it, adapt it.
