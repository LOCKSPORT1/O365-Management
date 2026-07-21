# 03-DeviceLifecycle

Three scripts covering device inventory, decommissioning, and Autopilot
enrollment for Intune-managed Windows devices.

### Prerequisites (all scripts)
- PowerShell 7.x recommended (see `00-Setup\Connect-M365Services.ps1` notes).
- `Install-Module Microsoft.Graph -Scope CurrentUser` (specifically the
  `Microsoft.Graph.DeviceManagement`, `Microsoft.Graph.DeviceManagement.Enrollment`,
  `Microsoft.Graph.Identity.DirectoryManagement`, and `Microsoft.Graph.Groups`
  sub-modules, depending on script).
- Every script dot-sources `00-Setup\Connect-M365Services.ps1` and calls
  `Assert-M365Connection` at the top, so it will self-connect (Interactive by
  default) if no session is already live. Pass `-AuthMode AppSecret` or
  `-AuthMode Certificate` for unattended/scheduled runs, matching whatever
  `$Global:M365Config` in `00-Setup` is populated with for your tenant.
- Minimum Graph scopes: `DeviceManagementManagedDevices.ReadWrite.All`,
  `DeviceManagementServiceConfig.ReadWrite.All` (Autopilot import/removal),
  `Device.ReadWrite.All` (Entra device object deletion), `Group.Read.All`
  (group lookup in `Register-AutopilotDevice.ps1`). Read-only inventory only
  needs `DeviceManagementManagedDevices.Read.All`.

---

## Get-IntuneDeviceInventory.ps1

### What it does
Exports every Intune-managed device to CSV with compliance state, last
sync, primary user, and flags for stale/orphaned devices. Good as a
scheduled monthly hygiene report. Read-only — makes no changes.

### Configuration
Config values are exposed directly as parameters (no separate hardcoded
block needed since there's nothing risky/destructive here):

| Parameter | Notes |
|---|---|
| `StaleThresholdDays` | Devices with no check-in longer than this get flagged `IsStale` (default 30) |
| `ExportPath` | CSV output location, defaults to current dir with today's date |
| `AuthMode` | `Interactive` (default), `AppSecret`, or `Certificate` |

### Usage
```powershell
.\Get-IntuneDeviceInventory.ps1 -StaleThresholdDays 45 -ExportPath "C:\Reports\Devices.csv"

# Unattended / scheduled task run
.\Get-IntuneDeviceInventory.ps1 -AuthMode Certificate
```

---

## Remove-IntuneDeviceLifecycle.ps1

### What it does
The device half of offboarding/decommissioning. Three actions:
- `Retire` — removes MDM management, keeps personal data (BYOD-friendly)
- `Wipe` — full factory reset (company-owned device decommission)
- `Delete` — removes a stale Intune record without touching the physical device (e.g. already reset/re-imaged)

Also optionally removes the Autopilot registration (`-RemoveAutopilotRegistration`)
and, for `Delete`, cleans up the matching Entra device object too.

Looks the target device up by exact `-DeviceName` match via
`Get-MgDeviceManagementManagedDevice`; refuses to proceed if zero or more
than one device matches the name (ambiguous names are treated as an error,
not a "pick one" — get the exact name/ID from `Get-IntuneDeviceInventory.ps1`
first).

### Configuration
```powershell
$Config = @{
    DestructiveActions = @("Retire","Wipe")   # actions gated by -Confirmed
}
```

### Parameters
| Parameter | Notes |
|---|---|
| `DeviceName` | Mandatory. Exact Intune device name match (not fuzzy). |
| `Action` | Mandatory. One of `Retire`, `Wipe`, `Delete`. |
| `RemoveAutopilotRegistration` | Also deletes the matching Autopilot identity by serial number. |
| `Confirmed` | Mandatory switch for `Retire`/`Wipe` — see Safety below. |
| `AuthMode` | `Interactive` (default), `AppSecret`, or `Certificate` |

### Safety
Built with `SupportsShouldProcess` (`ConfirmImpact = 'High'`, so `-WhatIf`/
`-Confirm` work and PowerShell will prompt by default on `Wipe`/`Retire`
even without `-Confirm` explicitly passed) **and** a separate, explicit
`-Confirmed` switch required for `Retire`/`Wipe`. The script checks for
`-Confirmed` **before** connecting to Graph or resolving the device, and
exits immediately without making any calls if it's missing — so a
mistyped device name or a script run without both flags cannot
accidentally wipe/retire the wrong (or any) machine. Every destructive
Graph call (`Invoke-MgRetireDeviceManagementManagedDevice`,
`Clear-MgDeviceManagementManagedDevice`, `Remove-MgDeviceManagementManagedDevice`,
`Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity`, `Remove-MgDevice`)
is also wrapped in `try/catch` so a failure on one step is reported clearly
instead of throwing an unhandled exception mid-run.

`Delete` is not in the destructive gate list (no `-Confirmed` required) since
it only removes a stale record for a device that's already gone/reset — but
it still respects `-WhatIf`/`-Confirm` via `ShouldProcess`.

### Usage
```powershell
# Dry run first
.\Remove-IntuneDeviceLifecycle.ps1 -DeviceName "PB-LAPTOP-0042" -Action Wipe -WhatIf

# For real - both -Confirmed AND ShouldProcess confirmation are required
.\Remove-IntuneDeviceLifecycle.ps1 -DeviceName "PB-LAPTOP-0042" -Action Wipe -Confirmed -RemoveAutopilotRegistration

# Retire (BYOD-style unenroll), unattended via cert auth
.\Remove-IntuneDeviceLifecycle.ps1 -DeviceName "PB-LAPTOP-0042" -Action Retire -Confirmed -AuthMode Certificate -Confirm:$false

# Cleanup of a stale/ghost record - not gated by -Confirmed
.\Remove-IntuneDeviceLifecycle.ps1 -DeviceName "PB-OLD-GHOST-01" -Action Delete
```

### Known gotchas
- Wipe/Retire commands only execute once the device next checks in with
  Intune — if it's offline (turned off, no network), nothing happens
  until it reconnects.
- Get the exact `DeviceName` from `Get-IntuneDeviceInventory.ps1` first —
  filtering is exact-match, not fuzzy. If more than one device shares the
  name, the script aborts rather than guessing which one you meant.
- The Graph SDK cmdlet for a full wipe is `Clear-MgDeviceManagementManagedDevice`
  (not `Invoke-MgWipeDeviceManagementManagedDevice`, which doesn't exist in
  the current SDK) — noted in-line in the script in case of future confusion.

---

## Register-AutopilotDevice.ps1

### What it does
Bulk-imports devices into Windows Autopilot from a CSV of hardware hashes
(`SerialNumber, HardwareHash, GroupTag` columns — the standard format from
Microsoft's `Get-WindowsAutoPilotInfo.ps1`, which is **not** included here
and needs to be run on each source device first, or provided by your
OEM/reseller). The hardware hash is decoded from Base64 text (as produced
by `Get-WindowsAutoPilotInfo.ps1`) into the byte array the Graph SDK
actually expects before submission — a plain string hash will fail
validation, so don't skip pre-processing the CSV.

### Configuration
```powershell
$Config = @{
    ImportPollIntervalSeconds = 30   # how often to poll import status with -WaitForImport
    ImportMaxWaitMinutes      = 15   # give up waiting after this long (import continues regardless)
    DefaultGroupTag           = ""   # used when a CSV row's GroupTag column is blank
    ImportRetryCount          = 2    # retries per device if the import call fails
    ImportRetryDelaySeconds   = 5    # delay between retries
}
```

### Parameters
| Parameter | Notes |
|---|---|
| `CsvPath` | Mandatory. Path to the hardware hash CSV. |
| `AssignToGroupName` | Optional — group to add devices to once they appear as Entra objects (lookup-only; see gotcha below, actual add-to-group is not yet automated). |
| `WaitForImport` | Polls import status instead of firing-and-forgetting. |
| `AuthMode` | `Interactive` (default), `AppSecret`, or `Certificate` |

### Usage
```powershell
.\Register-AutopilotDevice.ps1 -CsvPath "C:\Autopilot\NewDevices.csv" `
    -AssignToGroupName "SG-Autopilot-StandardLaptop" -WaitForImport

# Unattended import, no wait
.\Register-AutopilotDevice.ps1 -CsvPath "C:\Autopilot\NewDevices.csv" -AuthMode AppSecret
```

### Known gotchas
- Newly imported devices take anywhere from a few minutes to a few hours
  to show up as full Entra device objects — group assignment by device
  identity isn't instant. `-AssignToGroupName` only verifies the target
  group exists today; it warns/reminds you to run a separate group-add
  pass once devices show up in `Get-MgDevice` rather than blocking.
- If every row in the CSV fails to queue (e.g. bad file, bad hashes),
  `-WaitForImport` is skipped entirely with a warning instead of polling
  against an empty device list.
- Import status includes a `partial` state (imported with a non-fatal
  issue) in addition to `unknown`/`pending`/`complete`/`error` — treated
  as still-in-progress by the polling loop.
