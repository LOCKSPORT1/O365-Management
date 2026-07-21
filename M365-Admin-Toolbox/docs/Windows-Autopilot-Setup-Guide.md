**Windows Autopilot**

**Setup, Concepts & Department Automation Guide**

IT Deployment Reference — Generic Template

Prepared for: IT Department

July 12, 2026

*Companion files: Autopilot-DeploymentSetup.ps1, Autopilot-Deployment-Runbook.md*

Executive Summary

This guide covers Windows Autopilot from the ground up: what it is, how the pieces fit together, how to configure it by hand in the Intune admin center, and how the automation script handles department-based deployment (Sales, Sales - Branch 2, Engineering Workstation A, Engineering Workstation B, Warehouse, and any future group added to the configuration table).

The goal is that a new device only needs one manual action — registering it with the right Group Tag — and everything after that (join type, naming, OOBE behavior, local admin rights) happens automatically based on which department it belongs to.

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr class="odd">
<td><p><em><strong>What's in this document</strong></em></p>
<p>Sections 1–4 explain Autopilot concepts and prerequisites. Section 5 walks the manual Intune process. Sections 6–9 cover the automation script this project produced. Sections 10–12 cover verification, troubleshooting, and rollback. Section 13 summarizes deliverables. Appendix A contains the full script listing.</p></td>
</tr>
</tbody>
</table>

1\. What Is Windows Autopilot

Windows Autopilot is Microsoft's zero-touch provisioning service for Windows devices, built into Intune and Entra ID. Instead of imaging a machine by hand, a new or wiped PC is registered once (by its hardware hash), and from then on Intune recognizes it the moment it's powered on.

At first boot, the device checks in with the Autopilot service, downloads the deployment profile assigned to it, and runs through a customized Out-of-Box Experience (OOBE): skipping screens you don't need, joining Entra ID or your on-prem Active Directory (via Entra Connect), enrolling in Intune management, and installing whatever apps and policies are assigned — all before the end user ever sees a desktop.

The three moving parts you configure are: the device registration record, the deployment profile (what OOBE should do), and the group the profile is assigned to (who gets it). This document treats all three.

2\. Key Concepts

A short glossary, since the terminology is where most confusion starts.

| **Term**                      | **What it means**                                                                                                                                          |
|-------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Autopilot device registration | A record in Intune tied to one physical PC via its hardware hash. Created once, at intake.                                                                 |
| Group Tag                     | A short label attached to a device at registration time (e.g. Sales). This is the only thing that determines which department's profile a device receives. |
| Deployment Profile            | The settings applied during OOBE: join type, whether the user becomes a local admin, which screens are skipped, and the device naming pattern.             |
| Dynamic Security Group        | An Entra ID group whose membership is calculated automatically by a rule (any device with Group Tag = Sales), instead of being managed by hand.            |
| Assignment                    | The link between a deployment profile and a group. This is what actually causes a device in that group to receive that profile.                            |
| Azure AD Join                 | The device joins Entra ID only (cloud-native, no on-prem AD).                                                                                              |
| Hybrid Azure AD Join          | The device joins on-prem Active Directory and syncs to Entra ID via Entra Connect. This is the default used throughout this guide.                         |

3\. Prerequisites & Licensing

- Microsoft Intune license assigned to the tenant (included in Business Premium, E3/E5, or standalone Intune Plan).

- Microsoft Entra ID P1 or P2 (required for dynamic groups and automatic MDM enrollment).

- An account with the Intune Administrator role (or Global Admin) for profile/device management.

- An account with the Groups Administrator role (or Global Admin) for creating dynamic security groups.

- Entra Connect installed and syncing on-prem AD to Entra ID, healthy and running on schedule (confirm this is already in place in your environment).

- PowerShell 5.1+ or 7+, with the Microsoft.Graph.Authentication and Microsoft.Graph.Groups modules.

4\. End-to-End Deployment Lifecycle

The diagram below shows the full path a device takes from registration to a ready-to-use desktop.

<img src="media/765f0454c3a48c5821cbd1a6063e27fc43b5fec2.png" style="width:6.45833in;height:2.63542in" />

- Registered: a hardware hash is captured and uploaded to Intune, tagged with a Group Tag.

- Synced: the device object appears in Intune / Entra ID (for hybrid-joined devices, this depends on Entra Connect sync).

- Grouped: a dynamic group's membership rule matches the Group Tag and picks the device up automatically.

- Assigned: the deployment profile linked to that group is now the profile this device will receive.

- OOBE: the user powers the device on; it downloads the profile and customizes the out-of-box setup accordingly.

- Ready: the device joins the domain/Entra ID, enrolls in Intune, installs assigned apps, and is ready to use.

5\. Manual Setup in the Intune Admin Center

This section walks through doing all of this by hand, one department at a time. It's useful for understanding what the automation script does under the hood, or for one-off changes. Note: the Intune admin center's exact menu layout changes periodically, so treat these as navigation paths rather than pixel-perfect screenshots.

5.1 Register a device

Run this on the device itself, or feed it a hardware-hash CSV collected earlier:

Install-Script -Name Get-WindowsAutoPilotInfo -Force

Get-WindowsAutoPilotInfo.ps1 -Online -GroupTag "Sales"

5.2 Create a dynamic security group

Entra admin center → Groups → New group → Security → enable dynamic query membership type, then add a rule such as:

(device.devicePhysicalIds -any (\_ -contains "\[OrderID\]:Sales"))

5.3 Create a deployment profile

Intune admin center → Devices → Enrollment → Windows → Windows Autopilot deployment profiles → Create profile. Set the join type, device naming template, and which OOBE screens to hide, then save.

5.4 Assign the profile to the group

On the profile you just created, open Assignments and select the dynamic group from step 5.2. Devices matching that group's rule will pick up the profile the next time they check in.

5.5 Enrollment Status Page (optional)

Intune admin center → Devices → Enrollment → Windows → Enrollment Status Page lets you show install progress and block device use until required apps finish installing. Configure once; it applies tenant-wide unless scoped to specific groups.

6\. Our Automation Approach

Repeating sections 5.2–5.4 by hand for every department doesn't scale, and it's easy to fat-finger a membership rule. Autopilot-DeploymentSetup.ps1 replaces that manual process with a single editable table: add a row, run the script, and the group, profile, and assignment are created and linked automatically.

<img src="media/8bde2fd97ee8bde0969a6f37a10ab5b59b1bb6e9.png" style="width:5.83333in;height:3.29167in" />

Departments configured (examples — not fixed)

These were provided as a starting set. Add, rename, or remove rows in the script's Departments table as your org chart changes — see Section 7.

| **Key**         | **Display Name**          | **Group Tag**   | **Device Prefix** | **Local Admin** | **Join Type** |
|-----------------|---------------------------|-----------------|-------------------|-----------------|---------------|
| Sales           | Sales                     | Sales           | SAL-              | No              | Hybrid        |
| SalesBranch2    | Sales - Branch 2          | SalesBranch2    | SALB2-            | No              | Hybrid        |
| EngWorkstationA | Engineering Workstation A | EngWorkstationA | ENGA-             | Yes             | Hybrid        |
| EngWorkstationB | Engineering Workstation B | EngWorkstationB | ENGB-             | Yes             | Hybrid        |
| Warehouse       | Warehouse                 | Warehouse       | WHS-              | No              | Hybrid        |

7\. Script Walkthrough

The script is organized into three regions:

- CONFIGURATION — the only part you should routinely edit. Contains the default join type, default OOBE behavior, and the Departments table.

- FUNCTIONS — the logic that creates/finds groups, creates/finds profiles, and links them. No edits needed here.

- MAIN — the loop that runs the functions against every department (or one, with -Only) and prints/saves a summary.

Adding a department

Copy an existing block inside the Departments table and change the values:

\[PSCustomObject\]@{

Key = "Shipping"

DisplayName = "Shipping"

GroupTag = "Shipping"

DeviceNamePrefix = "SHP-"

JoinType = \$null \# inherits default (Hybrid)

LocalAdmin = \$false

Description = "Shipping/receiving scanning devices."

}

Keep Key short and unique, GroupTag exact (this is what you'll type at device registration), and DeviceNamePrefix short — Windows caps device names at 15 characters including the serial number.

8\. Registering Devices

This is the step that actually sorts a device into a department — the script only builds the plumbing; this points a device at it.

Install-Script -Name Get-WindowsAutoPilotInfo -Force

Get-WindowsAutoPilotInfo.ps1 -Online -GroupTag "Warehouse"

Replace the Group Tag value with the exact value from that department's row. Case and spelling both matter — copy/paste rather than retype.

9\. Running & Extending the Script

9.1 One-time prerequisites

Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Force

Install-Module -Name Microsoft.Graph.Groups -Scope CurrentUser -Force

9.2 Preview before making changes

.\Autopilot-DeploymentSetup.ps1 -DryRun

Prints every group, profile, and assignment it would create, including the JSON payload for each profile — nothing is written to the tenant.

9.3 Run for real

.\Autopilot-DeploymentSetup.ps1

Prompts for sign-in, then processes every department, skipping anything that already exists. Writes a timestamped CSV log of every group/profile ID it touched.

9.4 Run a single department

.\Autopilot-DeploymentSetup.ps1 -Only "Warehouse" -DryRun

.\Autopilot-DeploymentSetup.ps1 -Only "Warehouse"

10\. Verification Checklist

- Intune admin center → Devices → Enrollment → Windows Autopilot deployment profiles — confirm the profile exists with expected settings.

- Entra admin center → Groups → open Autopilot - \<Department\> — confirm the membership rule, then allow time for a matching device to populate.

- Register a real or test device with the matching Group Tag, then in Intune under Devices → Windows Autopilot devices, confirm Group Tag and that Profile status reaches Assigned.

- Boot the device through OOBE and confirm it follows the expected join type and skips the configured screens.

11\. Troubleshooting / Known Gotchas

- Group Tag typos are the most common failure. Compare the device's Group Tag in Intune against the script's GroupTag value character-for-character.

- Hybrid-joined devices need two syncs: Entra Connect (on-prem AD → Entra ID) and the Autopilot/Intune enrollment sync. Allow 15–30 minutes after registration.

- Dynamic group membership isn't instant even after sync — Entra ID's rule processing can take a few minutes.

- The join type is set by the profile's underlying type at creation and can't be toggled afterward — delete and recreate the profile if a department's join type was wrong.

12\. Rollback / Cleanup

The script never deletes anything automatically — removal is deliberate and manual, using the IDs from that run's CSV log:

Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeploymentProfiles/\<profileId\>"

Remove-MgGroup -GroupId "\<groupId\>"

13\. Project Summary — What We Built

Over this engagement, the following was produced:

| **File**                        | **Purpose**                                                                                                                    |
|---------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| Autopilot-DeploymentSetup.ps1   | Config-driven script that creates a dynamic group, deployment profile, and assignment per department, from one editable table. |
| Autopilot-Deployment-Runbook.md | Operational runbook: prerequisites, running the script, registering devices, verification, troubleshooting, rollback.          |
| This document                   | Full concept guide, manual walkthrough, and script reference — suitable for onboarding or handoff.                             |

Five example departments are configured (Sales, Sales - Branch 2, Engineering Workstation A, Engineering Workstation B, Warehouse), each producing its own Entra ID dynamic group, Autopilot deployment profile, and assignment. The table is designed to expand: adding a department is a copy/paste of one block, no other code changes required.

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr class="odd">
<td><p><em><strong>Bottom line</strong></em></p>
<p>Registering a device with the correct Group Tag is now the only manual step. Everything else — join type, device naming, admin rights, and OOBE behavior — is handled automatically based on the department it belongs to.</p></td>
</tr>
</tbody>
</table>

Appendix A: Full Script Listing — Autopilot-DeploymentSetup.ps1

\<#

.SYNOPSIS

Config-driven creation of Windows Autopilot dynamic groups, deployment profiles,

and the assignments linking them, one department at a time.

.DESCRIPTION

Creates, per row in the \$Departments table below:

1\. A dynamic Entra ID security group, keyed off the Autopilot "Group Tag" set

on each device at registration time.

2\. A Windows Autopilot deployment profile.

3\. The assignment linking that profile to that group.

Everything you'd normally click through in the Intune admin center is done here

via direct Microsoft Graph calls, driven entirely by the \$Departments table.

Add a row, run the script, done. Safe to re-run - existing groups/profiles are

detected by display name and skipped rather than duplicated.

You should only ever need to edit the CONFIGURATION region (the \$Departments

table, \$DefaultJoinType, \$DefaultOobeDefaults). Everything under FUNCTIONS and

MAIN is plumbing.

.PARAMETER DryRun

Preview mode. Prints every group/profile/assignment that WOULD be created,

including the JSON payload for each profile, without making any changes.

.PARAMETER Only

Restricts this run to a single department, matched by its Key field in the

\$Departments table (not its DisplayName).

.PARAMETER LogPath

Path for the timestamped CSV summary of every group/profile ID this run

touched. Defaults to AutopilotSetup-Log-\<timestamp\>.csv in the current

directory. Not written when -DryRun is used.

.EXAMPLE

.\Autopilot-DeploymentSetup.ps1 -DryRun

Shows what would be created for every department, no changes made.

.EXAMPLE

.\Autopilot-DeploymentSetup.ps1

Creates/updates everything for every department in \$Departments.

.EXAMPLE

.\Autopilot-DeploymentSetup.ps1 -Only "Sales"

Processes just the department whose Key is "Sales".

.NOTES

Prerequisites:

\- PowerShell 5.1+ (Windows PowerShell) or PowerShell 7+

\- Microsoft.Graph.Authentication and Microsoft.Graph.Groups modules

(auto-installed if missing)

\- An account with Intune Administrator (or equivalent) + Entra ID Groups

Administrator rights

\- Devices already registered in Autopilot with the matching -GroupTag value

(see the runbook, step "Registering a device")

\- If using Hybrid Azure AD Join (on-prem AD + Entra Connect), make sure Entra

Connect sync has run before checking group membership - dynamic groups

can't see a device until it's synced.

See Autopilot-Deployment-Runbook.md for full step-by-step instructions.

\#\>

\[CmdletBinding()\]

param(

\# Preview mode: no groups/profiles/assignments are created or changed.

\[switch\]\$DryRun,

\# Optional: restrict this run to a single department Key from the table below.

\[string\]\$Only,

\# Where the run summary CSV gets written.

\[string\]\$LogPath = (Join-Path -Path (Get-Location) -ChildPath ("AutopilotSetup-Log-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date)))

)

\#region ============================== CONFIGURATION ==============================

\# Graph API version to use for Autopilot-specific calls. Leave as v1.0 unless

\# Microsoft support/docs tell you a feature you need is beta-only.

\$GraphApiVersion = "v1.0"

\# Default join type for every department unless overridden per-row below.

\# "AzureADJoined" -\> Entra ID (cloud) join only

\# "HybridAzureADJoined" -\> On-prem AD join + Entra Connect sync (your case, likely)

\$DefaultJoinType = "HybridAzureADJoined"

\# Default OOBE behavior applied to every profile unless overridden per-row.

\$DefaultOobeDefaults = @{

HidePrivacySettings = \$true

HideEULA = \$true

SkipKeyboardSelection = \$true

HideChangeAccountOpts = \$true \# hides "escape link" for unauthenticated users

NotLocalAdmin = \$true \# \$true = primary user is a STANDARD user, not local admin

DeviceUsageType = "singleUser" \# "singleUser" or "shared"

}

\# ---- THE TABLE YOU EDIT -----------------------------------------------------

\# Key : short internal ID, no spaces. Used to build safe names, and

\# as the -Only filter value.

\# DisplayName : friendly name shown in Intune (used for both the group and

\# the profile, with prefixes added automatically below).

\# GroupTag : EXACT string you pass to Get-WindowsAutoPilotInfo.ps1 -GroupTag

\# when registering devices for this department. Case-sensitive

\# match against the device's Autopilot record.

\# DeviceNamePrefix : Prefix used in the profile's device naming template.

\# %SERIAL% is replaced by Windows with the device serial number.

\# Max 15 characters total including %SERIAL%'s expansion.

\# JoinType : Optional override of \$DefaultJoinType. Leave \$null to inherit.

\# LocalAdmin : \$true if the primary user should be a local admin (common for

\# CAD workstations that need to install/license software).

\# \$false = standard user (recommended default, e.g. Sales).

\# Description : Free text, shows up in Intune for anyone auditing the config.

\$Departments = @(

\[PSCustomObject\]@{

Key = "Sales"

DisplayName = "Sales"

GroupTag = "Sales"

DeviceNamePrefix = "SAL-"

JoinType = \$null

LocalAdmin = \$false

Description = "Standard sales laptops/desktops."

}

\[PSCustomObject\]@{

Key = "SalesBranch2"

DisplayName = "Sales - Branch 2"

GroupTag = "SalesBranch2"

DeviceNamePrefix = "SALB2-"

JoinType = \$null

LocalAdmin = \$false

Description = "Sales - secondary branch/site."

}

\[PSCustomObject\]@{

Key = "EngWorkstationA"

DisplayName = "Engineering Workstation A"

GroupTag = "EngWorkstationA"

DeviceNamePrefix = "ENGA-"

JoinType = \$null

LocalAdmin = \$true

Description = "Engineering workstations - application group A."

}

\[PSCustomObject\]@{

Key = "EngWorkstationB"

DisplayName = "Engineering Workstation B"

GroupTag = "EngWorkstationB"

DeviceNamePrefix = "ENGB-"

JoinType = \$null

LocalAdmin = \$true

Description = "Engineering workstations - application group B."

}

\[PSCustomObject\]@{

Key = "Warehouse"

DisplayName = "Warehouse"

GroupTag = "Warehouse"

DeviceNamePrefix = "WHS-"

JoinType = \$null

LocalAdmin = \$false

Description = "Warehouse / floor devices."

}

\# ---- ADD NEW DEPARTMENTS BY COPYING A BLOCK ABOVE ----

\# \[PSCustomObject\]@{

\# Key = "NewDept"

\# DisplayName = "New Department"

\# GroupTag = "NewDept"

\# DeviceNamePrefix = "NEW-"

\# JoinType = \$null

\# LocalAdmin = \$false

\# Description = "Describe this department here."

\# }

)

\#endregion =========================================================================

\#region ============================== FUNCTIONS ===================================

function Connect-ToGraph {

\$requiredModules = @(

"Microsoft.Graph.Authentication",

"Microsoft.Graph.Groups"

)

foreach (\$m in \$requiredModules) {

if (-not (Get-Module -ListAvailable -Name \$m)) {

Write-Host "Installing module \$m ..." -ForegroundColor Yellow

Install-Module -Name \$m -Scope CurrentUser -Force -AllowClobber

}

Import-Module -Name \$m -ErrorAction Stop

}

\$scopes = @(

"Group.ReadWrite.All",

"Device.ReadWrite.All",

"DeviceManagementServiceConfig.ReadWrite.All",

"DeviceManagementConfiguration.ReadWrite.All"

)

if (-not (Get-MgContext)) {

Connect-MgGraph -Scopes \$scopes \| Out-Null

}

Write-Host "Connected to tenant: \$((Get-MgContext).TenantId)" -ForegroundColor Green

}

function Get-OrCreateDeptGroup {

param(\[Parameter(Mandatory)\]\[PSCustomObject\]\$Dept)

\$groupName = "Autopilot - \$(\$Dept.DisplayName)"

\$membershipRule = '(device.devicePhysicalIds -any (\_ -contains "\[OrderID\]:{0}"))' -f \$Dept.GroupTag

\$existing = Get-MgGroup -Filter "displayName eq '\$groupName'" -ErrorAction SilentlyContinue

if (\$existing) {

Write-Host " \[Group\] Already exists: \$groupName" -ForegroundColor DarkGray

return \$existing

}

if (\$DryRun) {

Write-Host " \[Group\] DRY RUN - would create: \$groupName" -ForegroundColor Cyan

Write-Host " Rule: \$membershipRule" -ForegroundColor Cyan

return \[PSCustomObject\]@{ Id = "(dry-run-no-id)"; DisplayName = \$groupName }

}

\$nickname = (\$groupName -replace '\[^a-zA-Z0-9\]', '')

\$body = @{

displayName = \$groupName

description = "Auto-created for Autopilot. \$(\$Dept.Description)"

mailEnabled = \$false

mailNickname = \$nickname

securityEnabled = \$true

groupTypes = @("DynamicMembership")

membershipRule = \$membershipRule

membershipRuleProcessingState = "On"

}

Write-Host " \[Group\] Creating: \$groupName" -ForegroundColor Green

try {

\$new = New-MgGroup -BodyParameter \$body -ErrorAction Stop

}

catch {

throw "Failed to create group '\$groupName': \$(\$\_.Exception.Message)"

}

return \$new

}

function Get-OrCreateDeptProfile {

param(\[Parameter(Mandatory)\]\[PSCustomObject\]\$Dept)

\$profileName = "Autopilot - \$(\$Dept.DisplayName)"

\$joinType = if (\$Dept.JoinType) { \$Dept.JoinType } else { \$DefaultJoinType }

\$listUri = "https://graph.microsoft.com/\$GraphApiVersion/deviceManagement/windowsAutopilotDeploymentProfiles"

\$existingList = (Invoke-MgGraphRequest -Method GET -Uri \$listUri).value

\$existing = \$existingList \| Where-Object { \$\_.displayName -eq \$profileName }

if (\$existing) {

Write-Host " \[Profile\] Already exists: \$profileName" -ForegroundColor DarkGray

return \$existing

}

\$odataType = if (\$joinType -eq "HybridAzureADJoined") {

"#microsoft.graph.activeDirectoryWindowsAutopilotDeploymentProfile"

} else {

"#microsoft.graph.azureADWindowsAutopilotDeploymentProfile"

}

\$body = @{

"@odata.type" = \$odataType

displayName = \$profileName

description = \$Dept.Description

language = "os-default"

deviceNameTemplate = "\$(\$Dept.DeviceNamePrefix)%SERIAL%"

deviceType = "windowsPc"

outOfBoxExperienceSetting = @{

hidePrivacySettings = \$DefaultOobeDefaults.HidePrivacySettings

hideEULA = \$DefaultOobeDefaults.HideEULA

skipKeyboardSelectionPage = \$DefaultOobeDefaults.SkipKeyboardSelection

hideEscapeLinkForUnauthenticatedUser = \$DefaultOobeDefaults.HideChangeAccountOpts

deviceUsageType = \$DefaultOobeDefaults.DeviceUsageType

userType = if (\$Dept.LocalAdmin) { "administrator" } else { "standard" }

}

}

if (\$joinType -eq "HybridAzureADJoined") {

\$body\["hybridAzureADJoinSkipConnectivityCheck"\] = \$false

}

if (\$DryRun) {

Write-Host " \[Profile\] DRY RUN - would create: \$profileName (\$joinType)" -ForegroundColor Cyan

Write-Host (" " + (\$body \| ConvertTo-Json -Depth 5 -Compress)) -ForegroundColor Cyan

return \[PSCustomObject\]@{ id = "(dry-run-no-id)"; displayName = \$profileName }

}

Write-Host " \[Profile\] Creating: \$profileName (\$joinType)" -ForegroundColor Green

try {

\$new = Invoke-MgGraphRequest -Method POST -Uri \$listUri -Body (\$body \| ConvertTo-Json -Depth 5) -ErrorAction Stop

}

catch {

throw "Failed to create profile '\$profileName': \$(\$\_.Exception.Message)"

}

return \$new

}

function Set-DeptAssignment {

param(

\[Parameter(Mandatory)\]\[string\]\$ProfileId,

\[Parameter(Mandatory)\]\[string\]\$GroupId,

\[Parameter(Mandatory)\]\[string\]\$Label

)

if (\$DryRun -or \$ProfileId -eq "(dry-run-no-id)" -or \$GroupId -eq "(dry-run-no-id)") {

Write-Host " \[Assignment\] DRY RUN - would link profile to group for: \$Label" -ForegroundColor Cyan

return

}

\$assignUri = "https://graph.microsoft.com/\$GraphApiVersion/deviceManagement/windowsAutopilotDeploymentProfiles/\$ProfileId/assignments"

\$existingAssignments = (Invoke-MgGraphRequest -Method GET -Uri \$assignUri).value

\$alreadyLinked = \$existingAssignments \| Where-Object { \$\_.target.groupId -eq \$GroupId }

if (\$alreadyLinked) {

Write-Host " \[Assignment\] Already linked: \$Label" -ForegroundColor DarkGray

return

}

\$body = @{

target = @{

"@odata.type" = "#microsoft.graph.groupAssignmentTarget"

groupId = \$GroupId

}

}

Write-Host " \[Assignment\] Linking profile -\> group: \$Label" -ForegroundColor Green

try {

Invoke-MgGraphRequest -Method POST -Uri \$assignUri -Body (\$body \| ConvertTo-Json -Depth 5) -ErrorAction Stop \| Out-Null

}

catch {

throw "Failed to link profile to group for '\$Label': \$(\$\_.Exception.Message)"

}

}

\#endregion =========================================================================

\#region ================================ MAIN ======================================

Write-Host "\`n=== Windows Autopilot Deployment Setup ===" -ForegroundColor Magenta

if (\$DryRun) { Write-Host "\*\*\* DRY RUN MODE - no changes will be made \*\*\*\`n" -ForegroundColor Yellow }

Connect-ToGraph

\$targets = if (\$Only) {

\$Departments \| Where-Object { \$\_.Key -eq \$Only }

} else {

\$Departments

}

if (-not \$targets) {

Write-Warning "No departments matched. Check the -Only value or the \`\$Departments table."

return

}

\$errors = @()

\$results = foreach (\$dept in \$targets) {

Write-Host "\`n-- \$(\$dept.DisplayName) \[\$(\$dept.Key)\] --" -ForegroundColor White

\# Each department is wrapped independently so one failure (e.g. a Graph throttle,

\# a permissions gap, or a bad GroupTag/OData value) doesn't abort the rest of the

\# run - matches the per-step error collection used elsewhere in this toolset

\# (see M365-Admin-Toolkit's Invoke-M365UserOffboarding.ps1).

try {

\$group = Get-OrCreateDeptGroup -Dept \$dept

\$deptProfile = Get-OrCreateDeptProfile -Dept \$dept

Set-DeptAssignment -ProfileId \$deptProfile.id -GroupId \$group.Id -Label \$dept.DisplayName

\[PSCustomObject\]@{

Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Department = \$dept.DisplayName

Key = \$dept.Key

GroupTag = \$dept.GroupTag

GroupName = \$group.DisplayName

GroupId = \$group.Id

ProfileName = \$deptProfile.displayName

ProfileId = \$deptProfile.id

JoinType = if (\$dept.JoinType) { \$dept.JoinType } else { \$DefaultJoinType }

LocalAdmin = \$dept.LocalAdmin

DryRun = \[bool\]\$DryRun

}

}

catch {

\$errors += "\$(\$dept.DisplayName) \[\$(\$dept.Key)\]: \$(\$\_.Exception.Message)"

Write-Host " \[FAILED\] \$(\$dept.DisplayName): \$(\$\_.Exception.Message)" -ForegroundColor Red

}

}

Write-Host "\`n=== Summary ===" -ForegroundColor Magenta

\$results \| Format-Table Department, GroupTag, GroupId, ProfileId, JoinType, LocalAdmin -AutoSize

if (\$errors.Count -gt 0) {

Write-Host "\`n\$(\$errors.Count) department(s) failed - review before assuming the run is complete:" -ForegroundColor Red

\$errors \| ForEach-Object { Write-Host " - \$\_" -ForegroundColor Red }

}

if (-not \$DryRun) {

\$results \| Export-Csv -Path \$LogPath -NoTypeInformation

Write-Host "\`nLog written to: \$LogPath" -ForegroundColor Green

} else {

Write-Host "\`n(No log file written in dry-run mode.)" -ForegroundColor Yellow

}

\#endregion =========================================================================
