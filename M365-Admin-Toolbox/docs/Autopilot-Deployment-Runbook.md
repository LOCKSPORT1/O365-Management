# Windows Autopilot Deployment Runbook

Companion to `Autopilot-DeploymentSetup.ps1`. This runbook covers prerequisites, how
to run the script safely, how to register devices so they land in the right
department, how to add new departments, and how to verify/roll back.

Environment assumption: on-prem AD synced to Entra ID via Entra Connect, Intune
connector already installed. That means devices in this setup are **Hybrid Azure
AD Joined** by default (see `$DefaultJoinType` in the script). If your tenant is
cloud-only, change `$DefaultJoinType` to `AzureADJoined` before running.

---

## 1. What this actually builds

For each row in the script's `$Departments` table, three things get created in
your tenant:

1. **A dynamic Entra ID security group** named `Autopilot - <DisplayName>`,
   with a membership rule that automatically pulls in any device whose
   Autopilot Group Tag matches.
2. **A Windows Autopilot deployment profile** named `Autopilot - <DisplayName>`,
   controlling what happens at OOBE (join type, local admin or not, device
   naming pattern, EULA/privacy screens, etc.).
3. **An assignment** linking that profile to that group.

Nothing targets an individual device directly. The device's **Group Tag**
(set at registration time) is the only thing that determines which department
it falls into.

---

## 2. One-time setup

### 2.1 Install prerequisites (run once, on any admin workstation)

```powershell
Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Force
Install-Module -Name Microsoft.Graph.Groups -Scope CurrentUser -Force
```

The main script will also auto-install these if missing, but doing it up front
avoids consent prompts mid-run.

### 2.2 Confirm permissions

The account you sign in with needs, at minimum:
- **Intune Administrator** (or Global Admin) — to create/assign Autopilot profiles
- **Groups Administrator** (or Global Admin) — to create dynamic security groups

### 2.3 Confirm Entra Connect sync is healthy (hybrid-joined tenants only)

Dynamic groups can only see devices that exist as objects in Entra ID. For
hybrid-joined devices, that means the device object must have synced from
on-prem AD first. If sync is delayed or broken, a device can be Autopilot
"registered" but invisible to the dynamic group until sync catches up.

Quick check on your Entra Connect server:
```powershell
Get-ADSyncScheduler
Start-ADSyncSyncCycle -PolicyType Delta   # force an immediate sync if needed
```

---

## 3. Registering a device into a department

This is the step that actually determines which profile a device gets — the
script only builds the plumbing, this step points a device at it.

On the device itself (or via whatever imaging/reference process you use):

```powershell
Install-Script -Name Get-WindowsAutoPilotInfo -Force
Get-WindowsAutoPilotInfo.ps1 -Online -GroupTag "Sales"
```

Replace `"Sales"` with the **exact** `GroupTag` value from the department's
row in `$Departments`. Case matters. `-Online` uploads the hardware hash to
Intune directly (you'll be prompted to sign in with an account that has
Intune enrollment rights).

If you're registering in bulk (e.g., a stack of new laptops before shipping to
sites), you can instead export hashes to CSV and bulk-import via
`Import-AutopilotCSV` — ask if you want that variant added to the script.

---

## 4. Running the setup script

All commands below assume you're in the folder containing both files
(`M365-Admin-Toolbox\intune\`).

### 4.1 Preview first — always

```powershell
.\Autopilot-DeploymentSetup.ps1 -DryRun
```

This prints exactly what groups, profiles, and assignments it *would* create,
including the full JSON payload for each profile, without touching your
tenant. Read this output before running for real, especially the first time.

### 4.2 Run for real

```powershell
.\Autopilot-DeploymentSetup.ps1
```

You'll get an interactive Microsoft Entra sign-in prompt (device code or
browser popup depending on your PowerShell host). After sign-in, it processes
every department in the table, skips anything that already exists (safe to
re-run), and writes a timestamped CSV log (`AutopilotSetup-Log-*.csv`) with
every group/profile ID it touched.

### 4.3 Run just one department

Useful when you've added a single new row and don't want to re-touch
everything else:

```powershell
.\Autopilot-DeploymentSetup.ps1 -Only "EngWorkstationA" -DryRun
.\Autopilot-DeploymentSetup.ps1 -Only "EngWorkstationA"
```

The value passed to `-Only` is the `Key` field from the table, not the
display name.

---

## 5. Adding or changing a department

Open `Autopilot-DeploymentSetup.ps1`, find the `$Departments` table in the
`CONFIGURATION` region, and copy one of the existing blocks:

```powershell
[PSCustomObject]@{
    Key              = "Shipping"
    DisplayName      = "Shipping"
    GroupTag         = "Shipping"
    DeviceNamePrefix = "SHP-"
    JoinType         = $null        # inherits $DefaultJoinType
    LocalAdmin       = $false
    Description      = "Shipping/receiving scanning devices."
}
```

Rules of thumb:
- **Key**: no spaces, unique, used with `-Only`.
- **GroupTag**: this is the string you'll type into
  `Get-WindowsAutoPilotInfo.ps1 -GroupTag` for every device in that
  department. Keep it short and typo-proof — copy/paste it rather than
  retyping at registration time.
- **DeviceNamePrefix**: total device name (prefix + serial) is capped at 15
  characters by Windows. Keep prefixes to 6-8 characters.
- **LocalAdmin**: `$true` for workstations where the end user needs to
  install/license software themselves (common for engineering/CAD-style
  apps); `$false` for locked-down standard users (typical for sales/office
  staff).

Then run:
```powershell
.\Autopilot-DeploymentSetup.ps1 -Only "Shipping" -DryRun
.\Autopilot-DeploymentSetup.ps1 -Only "Shipping"
```

Renaming a `DisplayName` after the group/profile already exist will create a
**new** group and profile rather than renaming the old ones (the script
matches by name to decide "does this already exist"). Change `DisplayName`
only if you intend to fully replace that department's Autopilot config, and
clean up the old group/profile afterward (Section 7).

---

## 6. Verifying it worked

1. **Intune admin center** → Devices → Enrollment → Windows Autopilot deployment
   profiles — confirm the profile exists with expected settings.
2. **Entra admin center** → Groups — open `Autopilot - <Department>`, check
   Membership rule, and give it a minute to populate once a matching device
   syncs.
3. Register a real (or test) device with the matching Group Tag, then in
   Intune under **Devices → Windows Autopilot devices**, confirm:
   - `Group Tag` matches what you expect
   - `Profile status` moves to **Assigned**
4. Boot the device (or a VM) through OOBE and confirm it follows the expected
   join type and skips the screens you configured.

---

## 7. Rollback / cleanup

There's no destructive logic in the main script by design — it only ever
creates or links, never deletes. To remove a department's objects, do it by
hand (deliberately, so nothing gets deleted by accident):

```powershell
# Remove the assignment + profile
$p = Get-MgGraphRequestResult  # or look up via Intune admin center
Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeploymentProfiles/<profileId>"

# Remove the group
Remove-MgGroup -GroupId "<groupId>"
```

Use the `GroupId` / `ProfileId` values from that run's CSV log
(`AutopilotSetup-Log-*.csv`) to find the right IDs.

---

## 8. Known gotchas

- **Group Tag typos are the #1 failure mode.** If a device doesn't land in
  the group you expect, check the exact Group Tag on the device record in
  Intune against the `GroupTag` value in the script — whitespace and case
  both matter.
- **Hybrid join devices need two syncs**, not one: Entra Connect (on-prem AD
  → Entra ID) and the Autopilot/Intune enrollment sync. Give it 15-30 minutes
  after registration before assuming something's broken.
- **Dynamic group membership isn't instant.** Even after sync, Entra ID's
  dynamic group processing can take a few minutes to catch up.
- **`@odata.type` in the profile payload determines Hybrid vs. cloud-only
  join** — it isn't a separate flag you can toggle after creation. If a
  department's `JoinType` was wrong, delete and recreate that profile rather
  than trying to patch it.

---

## 9. Support boundaries

This runbook and script cover the Autopilot profile/group side only. It does
not cover: app assignment, Enrollment Status Page configuration, compliance
policies, or Configuration Manager task sequences for existing-device
scenarios.
