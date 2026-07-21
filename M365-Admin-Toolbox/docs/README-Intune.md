# Intune scripts

## Device-Onboarding.ps1
Finds managed devices for a user and can trigger a device sync.

## Device-Offboarding.ps1
Handles retire, wipe, and Entra device disable actions.

### Notes
- These scripts connect to Graph at runtime.
- Intune cmdlets are accessed through the Graph PowerShell SDK.
- Device actions should be tested on a pilot device group before broad use.


## Report-StaleDevices.ps1
Builds a report of managed devices that have not synced within the specified number of days.

## Cleanup-StaleDevices.ps1
Can retire or delete stale managed devices after reporting candidates first.


## Report-AutopilotDevices.ps1
Exports Windows Autopilot device identity data through Microsoft Graph.

## Autopilot-DeploymentSetup.ps1
Standalone script (own Graph connection, not `core\Connect-M365.ps1`) that builds
the department-based Autopilot deployment structure: a dynamic Entra ID group, a
deployment profile, and the assignment linking them, for each row in its
`$Departments` table. Ships with generic example departments - replace with your
organization's real breakdown before running for real. Supports `-DryRun` (preview
only) and `-Only <Key>` (single department). Full walkthrough:
`docs\Autopilot-Deployment-Runbook.md` (or the formatted `Windows-Autopilot-Setup-Guide.docx`).
