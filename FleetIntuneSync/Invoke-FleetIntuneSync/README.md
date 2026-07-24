# Fleet Intune Sync

Force an Intune check-in across your entire managed fleet (or a filtered slice of it) via Microsoft Graph — with a device-side companion script for the stubborn stragglers.

## Why this exists

Intune devices check in on a roughly 8-hour cadence. After you change policy assignments — retiring a conflicting profile, re-scoping a security baseline, consolidating a double-sourced setting — you often want the fleet to re-evaluate *now*, not over the next work day. Clicking **Sync** per device in the portal doesn't scale past a handful of machines.

This toolkit sends the sync action to every matching device through the Graph API, with throttling protection, a preview mode, and honest expectation-setting about what "sync" actually does.

## What's in the box

| File | Runs on | Purpose |
|---|---|---|
| `Invoke-FleetIntuneSync.ps1` | Your admin workstation | Graph-side fleet sync with filters, WhatIf preview, 429 backoff, and a summary report |
| `Start-IntuneCheckin-DeviceSide.ps1` | Endpoints (via RMM, as SYSTEM) | Fires the OMA-DM `PushLaunch` scheduled task from the device side — for devices that miss the WNS push |

## Requirements

- PowerShell 5.1+ or PowerShell 7
- `Microsoft.Graph.DeviceManagement` module (auto-installed to CurrentUser scope if missing)
- An account that can consent to / has been granted the Graph scope
  `DeviceManagementManagedDevices.PrivilegedOperations.All`
  (Intune Administrator or Global Administrator typically works; interactive sign-in, **no app registration required**)

## Quick start

```powershell
# 1. Preview — see exactly which devices would be targeted, sync nothing
.\Invoke-FleetIntuneSync.ps1 -WhatIfMode

# 2. Sync every Windows device in the tenant
.\Invoke-FleetIntuneSync.ps1

# 3. Sync a named slice, capped for safety
.\Invoke-FleetIntuneSync.ps1 -DeviceNameFilter 'SALES-*' -MaxDevices 50
```

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `-WhatIfMode` | off | Lists targets and exits. Run this first. Always. |
| `-OperatingSystem` | `Windows` | Server-side Graph filter. Pass `''` to target all OSes. |
| `-DeviceNameFilter` | *(none)* | Client-side wildcard on device name, e.g. `'LAB-*'`. |
| `-MaxDevices` | `0` (unlimited) | Hard cap on targets. |
| `-ThrottleDelayMs` | `200` | Pause between calls. Raise in very large tenants if you see repeated 429 backoffs. |

## The most important thing to understand

**Sync ≠ instant dashboards.** The sync action makes devices *check in* quickly — online devices typically within minutes. But the Intune portal's compliance and conflict **reporting pipeline lags hours behind** the check-ins. If you retire a conflicting profile, fire a fleet sync, and stare at the conflict-count donut 20 minutes later, it will look like nothing happened.

Judge progress per-device instead: pick a canary machine and inspect its actual policy state (e.g., via a per-device deployment-issues report, `dsregcmd /status`, or the device's Configuration blade), and let the dashboards catch up overnight.

Other expectations worth setting:

- **Offline devices** receive the sync request when they next connect. The script reports "sent," not "received."
- The Graph sync depends on a **WNS push** reaching the device. Networks that block the push channel will queue the request until the next natural check-in — that's what the device-side companion script is for.

## Device-side companion (RMM path)

Deploy `Start-IntuneCheckin-DeviceSide.ps1` through your RMM (NinjaOne, ConnectWise, Datto, Intune itself via a script/remediation, etc.) running as **SYSTEM**. It starts the `PushLaunch` scheduled task under `\Microsoft\Windows\EnterpriseMgmt\`, which initiates an OMA-DM session from the device outward — no inbound push required.

Exit codes: `0` = fired (or not MDM-enrolled, stated in output), `1` = task present but failed to start.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Authentication needed. Please call Connect-MgGraph.` | No Graph session | The script self-connects; if running commands manually, `Connect-MgGraph -Scopes "DeviceManagementManagedDevices.PrivilegedOperations.All"` |
| HTTP 403 on the sync call | Session cached from an earlier connection **without** the privileged-operations scope | `Disconnect-MgGraph`, then rerun. The script does this automatically when it detects a scope mismatch. The Graph SDK token cache reuses old tokens even after you "reconnect" — explicit disconnect is the cure. |
| Repeated 429 backoff messages | Tenant-level Graph throttling | Raise `-ThrottleDelayMs` (e.g., 500–1000) or run in slices with `-DeviceNameFilter` |
| Conflict counts unchanged hours later | Reporting-pipeline lag (normal) | Wait 24 h; verify per-device in the meantime |
| A device never checks in | Offline, or WNS blocked | Use the device-side companion script via RMM |

## Typical workflow: policy-change drain

1. Make the assignment change (unassign/re-scope the conflicting profile) and **Save**.
   - New enrollments evaluate against current assignments immediately — a device enrolling after the Save never sees the retired profile. The fleet sync is for the *existing* population.
2. `.\Invoke-FleetIntuneSync.ps1 -WhatIfMode` — sanity-check the target list.
3. `.\Invoke-FleetIntuneSync.ps1` — fire the fleet.
4. Verify on a canary device within the hour.
5. Check the portal's conflict counters the **next day**, not the next hour.

## License

MIT. Adapt freely; attribution appreciated.
