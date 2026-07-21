<#
.SYNOPSIS
    Config-driven creation of Windows Autopilot dynamic groups, deployment profiles,
    and the assignments linking them, one department at a time.

.DESCRIPTION
    Creates, per row in the $Departments table below:
      1. A dynamic Entra ID security group, keyed off the Autopilot "Group Tag" set
         on each device at registration time.
      2. A Windows Autopilot deployment profile.
      3. The assignment linking that profile to that group.

    Everything you'd normally click through in the Intune admin center is done here
    via direct Microsoft Graph calls, driven entirely by the $Departments table.
    Add a row, run the script, done. Safe to re-run - existing groups/profiles are
    detected by display name and skipped rather than duplicated.

    You should only ever need to edit the CONFIGURATION region (the $Departments
    table, $DefaultJoinType, $DefaultOobeDefaults). Everything under FUNCTIONS and
    MAIN is plumbing.

    Standalone script - not built on core\Connect-M365.ps1 / config\tenants.json.
    It manages its own Microsoft.Graph connection (same pattern as
    entra\Audit-LicenseWaste.ps1 and entra\Audit-StaleAccounts.ps1 in this toolbox).

.PARAMETER DryRun
    Preview mode. Prints every group/profile/assignment that WOULD be created,
    including the JSON payload for each profile, without making any changes.

.PARAMETER Only
    Restricts this run to a single department, matched by its Key field in the
    $Departments table (not its DisplayName).

.PARAMETER LogPath
    Path for the timestamped CSV summary of every group/profile ID this run
    touched. Defaults to AutopilotSetup-Log-<timestamp>.csv in the current
    directory. Not written when -DryRun is used.

.EXAMPLE
    .\Autopilot-DeploymentSetup.ps1 -DryRun
    Shows what would be created for every department, no changes made.

.EXAMPLE
    .\Autopilot-DeploymentSetup.ps1
    Creates/updates everything for every department in $Departments.

.EXAMPLE
    .\Autopilot-DeploymentSetup.ps1 -Only "Sales"
    Processes just the department whose Key is "Sales".

.NOTES
    Prerequisites:
      - PowerShell 5.1+ (Windows PowerShell) or PowerShell 7+
      - Microsoft.Graph.Authentication and Microsoft.Graph.Groups modules
        (auto-installed if missing)
      - An account with Intune Administrator (or equivalent) + Entra ID Groups
        Administrator rights
      - Devices already registered in Autopilot with the matching -GroupTag value
        (see the runbook, step "Registering a device")
      - If using Hybrid Azure AD Join (on-prem AD + Entra Connect), make sure Entra
        Connect sync has run before checking group membership - dynamic groups
        can't see a device until it's synced.

    Replace the example $Departments rows below with your organization's real
    department/group-tag breakdown before running for real - see
    docs\Autopilot-Deployment-Runbook.md for full step-by-step instructions.
#>

[CmdletBinding()]
param(
    # Preview mode: no groups/profiles/assignments are created or changed.
    [switch]$DryRun,

    # Optional: restrict this run to a single department Key from the table below.
    [string]$Only,

    # Where the run summary CSV gets written.
    [string]$LogPath = (Join-Path -Path (Get-Location) -ChildPath ("AutopilotSetup-Log-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date)))
)

#region ============================== CONFIGURATION ==============================

# Graph API version to use for Autopilot-specific calls. Leave as v1.0 unless
# Microsoft support/docs tell you a feature you need is beta-only.
$GraphApiVersion = "v1.0"

# Default join type for every department unless overridden per-row below.
#   "AzureADJoined"       -> Entra ID (cloud) join only
#   "HybridAzureADJoined" -> On-prem AD join + Entra Connect sync
$DefaultJoinType = "HybridAzureADJoined"

# Default OOBE behavior applied to every profile unless overridden per-row.
$DefaultOobeDefaults = @{
    HidePrivacySettings   = $true
    HideEULA              = $true
    SkipKeyboardSelection = $true
    HideChangeAccountOpts = $true     # hides "escape link" for unauthenticated users
    NotLocalAdmin         = $true     # $true = primary user is a STANDARD user, not local admin
    DeviceUsageType       = "singleUser"   # "singleUser" or "shared"
}

# ---- THE TABLE YOU EDIT -----------------------------------------------------
# Key              : short internal ID, no spaces. Used to build safe names, and
#                    as the -Only filter value.
# DisplayName      : friendly name shown in Intune (used for both the group and
#                    the profile, with prefixes added automatically below).
# GroupTag         : EXACT string you pass to Get-WindowsAutoPilotInfo.ps1 -GroupTag
#                    when registering devices for this department. Case-sensitive
#                    match against the device's Autopilot record.
# DeviceNamePrefix : Prefix used in the profile's device naming template.
#                    %SERIAL% is replaced by Windows with the device serial number.
#                    Max 15 characters total including %SERIAL%'s expansion.
# JoinType         : Optional override of $DefaultJoinType. Leave $null to inherit.
# LocalAdmin       : $true if the primary user should be a local admin (common for
#                    workstations that need to install/license their own software).
#                    $false = standard user (recommended default).
# Description      : Free text, shows up in Intune for anyone auditing the config.
#
# Rows below are generic examples - replace with your organization's real
# department/group-tag breakdown. See docs\Autopilot-Deployment-Runbook.md section 5.

$Departments = @(
    [PSCustomObject]@{
        Key              = "Sales"
        DisplayName      = "Sales"
        GroupTag         = "Sales"
        DeviceNamePrefix = "SAL-"
        JoinType         = $null
        LocalAdmin       = $false
        Description      = "Standard sales laptops/desktops."
    }
    [PSCustomObject]@{
        Key              = "SalesBranch2"
        DisplayName      = "Sales - Branch 2"
        GroupTag         = "SalesBranch2"
        DeviceNamePrefix = "SALB2-"
        JoinType         = $null
        LocalAdmin       = $false
        Description      = "Sales - secondary branch/site."
    }
    [PSCustomObject]@{
        Key              = "EngWorkstationA"
        DisplayName      = "Engineering Workstation A"
        GroupTag         = "EngWorkstationA"
        DeviceNamePrefix = "ENGA-"
        JoinType         = $null
        LocalAdmin       = $true
        Description      = "Engineering workstations - application group A."
    }
    [PSCustomObject]@{
        Key              = "EngWorkstationB"
        DisplayName      = "Engineering Workstation B"
        GroupTag         = "EngWorkstationB"
        DeviceNamePrefix = "ENGB-"
        JoinType         = $null
        LocalAdmin       = $true
        Description      = "Engineering workstations - application group B."
    }
    [PSCustomObject]@{
        Key              = "Warehouse"
        DisplayName      = "Warehouse"
        GroupTag         = "Warehouse"
        DeviceNamePrefix = "WHS-"
        JoinType         = $null
        LocalAdmin       = $false
        Description      = "Warehouse / floor devices."
    }

    # ---- ADD NEW DEPARTMENTS BY COPYING A BLOCK ABOVE ----
    # [PSCustomObject]@{
    #     Key              = "NewDept"
    #     DisplayName      = "New Department"
    #     GroupTag         = "NewDept"
    #     DeviceNamePrefix = "NEW-"
    #     JoinType         = $null
    #     LocalAdmin       = $false
    #     Description      = "Describe this department here."
    # }
)

#endregion =========================================================================

#region ============================== FUNCTIONS ===================================

function Connect-ToGraph {
    $requiredModules = @(
        "Microsoft.Graph.Authentication",
        "Microsoft.Graph.Groups"
    )
    foreach ($m in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Write-Host "Installing module $m ..." -ForegroundColor Yellow
            Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber
        }
        Import-Module -Name $m -ErrorAction Stop
    }

    $scopes = @(
        "Group.ReadWrite.All",
        "Device.ReadWrite.All",
        "DeviceManagementServiceConfig.ReadWrite.All",
        "DeviceManagementConfiguration.ReadWrite.All"
    )

    if (-not (Get-MgContext)) {
        Connect-MgGraph -Scopes $scopes | Out-Null
    }
    Write-Host "Connected to tenant: $((Get-MgContext).TenantId)" -ForegroundColor Green
}

function Get-OrCreateDeptGroup {
    param([Parameter(Mandatory)][PSCustomObject]$Dept)

    $groupName = "Autopilot - $($Dept.DisplayName)"
    $membershipRule = '(device.devicePhysicalIds -any (_ -contains "[OrderID]:{0}"))' -f $Dept.GroupTag

    $existing = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction SilentlyContinue

    if ($existing) {
        Write-Host "  [Group] Already exists: $groupName" -ForegroundColor DarkGray
        return $existing
    }

    if ($DryRun) {
        Write-Host "  [Group] DRY RUN - would create: $groupName" -ForegroundColor Cyan
        Write-Host "          Rule: $membershipRule" -ForegroundColor Cyan
        return [PSCustomObject]@{ Id = "(dry-run-no-id)"; DisplayName = $groupName }
    }

    $nickname = ($groupName -replace '[^a-zA-Z0-9]', '')
    $body = @{
        displayName                  = $groupName
        description                  = "Auto-created for Autopilot. $($Dept.Description)"
        mailEnabled                  = $false
        mailNickname                 = $nickname
        securityEnabled              = $true
        groupTypes                   = @("DynamicMembership")
        membershipRule               = $membershipRule
        membershipRuleProcessingState = "On"
    }

    Write-Host "  [Group] Creating: $groupName" -ForegroundColor Green
    try {
        $new = New-MgGroup -BodyParameter $body -ErrorAction Stop
    }
    catch {
        throw "Failed to create group '$groupName': $($_.Exception.Message)"
    }
    return $new
}

function Get-OrCreateDeptProfile {
    param([Parameter(Mandatory)][PSCustomObject]$Dept)

    $profileName = "Autopilot - $($Dept.DisplayName)"
    $joinType = if ($Dept.JoinType) { $Dept.JoinType } else { $DefaultJoinType }

    $listUri = "https://graph.microsoft.com/$GraphApiVersion/deviceManagement/windowsAutopilotDeploymentProfiles"
    $existingList = (Invoke-MgGraphRequest -Method GET -Uri $listUri).value
    $existing = $existingList | Where-Object { $_.displayName -eq $profileName }

    if ($existing) {
        Write-Host "  [Profile] Already exists: $profileName" -ForegroundColor DarkGray
        return $existing
    }

    $odataType = if ($joinType -eq "HybridAzureADJoined") {
        "#microsoft.graph.activeDirectoryWindowsAutopilotDeploymentProfile"
    } else {
        "#microsoft.graph.azureADWindowsAutopilotDeploymentProfile"
    }

    $body = @{
        "@odata.type"      = $odataType
        displayName        = $profileName
        description        = $Dept.Description
        language           = "os-default"
        deviceNameTemplate = "$($Dept.DeviceNamePrefix)%SERIAL%"
        deviceType         = "windowsPc"
        outOfBoxExperienceSetting = @{
            hidePrivacySettings                  = $DefaultOobeDefaults.HidePrivacySettings
            hideEULA                             = $DefaultOobeDefaults.HideEULA
            skipKeyboardSelectionPage            = $DefaultOobeDefaults.SkipKeyboardSelection
            hideEscapeLinkForUnauthenticatedUser = $DefaultOobeDefaults.HideChangeAccountOpts
            deviceUsageType                      = $DefaultOobeDefaults.DeviceUsageType
            userType                             = if ($Dept.LocalAdmin) { "administrator" } else { "standard" }
        }
    }

    if ($joinType -eq "HybridAzureADJoined") {
        $body["hybridAzureADJoinSkipConnectivityCheck"] = $false
    }

    if ($DryRun) {
        Write-Host "  [Profile] DRY RUN - would create: $profileName ($joinType)" -ForegroundColor Cyan
        Write-Host ("          " + ($body | ConvertTo-Json -Depth 5 -Compress)) -ForegroundColor Cyan
        return [PSCustomObject]@{ id = "(dry-run-no-id)"; displayName = $profileName }
    }

    Write-Host "  [Profile] Creating: $profileName ($joinType)" -ForegroundColor Green
    try {
        $new = Invoke-MgGraphRequest -Method POST -Uri $listUri -Body ($body | ConvertTo-Json -Depth 5) -ErrorAction Stop
    }
    catch {
        throw "Failed to create profile '$profileName': $($_.Exception.Message)"
    }
    return $new
}

function Set-DeptAssignment {
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$Label
    )

    if ($DryRun -or $ProfileId -eq "(dry-run-no-id)" -or $GroupId -eq "(dry-run-no-id)") {
        Write-Host "  [Assignment] DRY RUN - would link profile to group for: $Label" -ForegroundColor Cyan
        return
    }

    $assignUri = "https://graph.microsoft.com/$GraphApiVersion/deviceManagement/windowsAutopilotDeploymentProfiles/$ProfileId/assignments"
    $existingAssignments = (Invoke-MgGraphRequest -Method GET -Uri $assignUri).value
    $alreadyLinked = $existingAssignments | Where-Object { $_.target.groupId -eq $GroupId }

    if ($alreadyLinked) {
        Write-Host "  [Assignment] Already linked: $Label" -ForegroundColor DarkGray
        return
    }

    $body = @{
        target = @{
            "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
            groupId       = $GroupId
        }
    }

    Write-Host "  [Assignment] Linking profile -> group: $Label" -ForegroundColor Green
    try {
        Invoke-MgGraphRequest -Method POST -Uri $assignUri -Body ($body | ConvertTo-Json -Depth 5) -ErrorAction Stop | Out-Null
    }
    catch {
        throw "Failed to link profile to group for '$Label': $($_.Exception.Message)"
    }
}

#endregion =========================================================================

#region ================================ MAIN ======================================

Write-Host "`n=== Windows Autopilot Deployment Setup ===" -ForegroundColor Magenta
if ($DryRun) { Write-Host "*** DRY RUN MODE - no changes will be made ***`n" -ForegroundColor Yellow }

Connect-ToGraph

$targets = if ($Only) {
    $Departments | Where-Object { $_.Key -eq $Only }
} else {
    $Departments
}

if (-not $targets) {
    Write-Warning "No departments matched. Check the -Only value or the `$Departments table."
    return
}

$errors = @()

$results = foreach ($dept in $targets) {
    Write-Host "`n-- $($dept.DisplayName) [$($dept.Key)] --" -ForegroundColor White

    # Each department is wrapped independently so one failure (e.g. a Graph throttle,
    # a permissions gap, or a bad GroupTag/OData value) doesn't abort the rest of the
    # run - matches the per-step error collection used elsewhere in this toolset
    # (see M365-Admin-Toolkit's Invoke-M365UserOffboarding.ps1).
    try {
        $group       = Get-OrCreateDeptGroup   -Dept $dept
        $deptProfile = Get-OrCreateDeptProfile -Dept $dept
        Set-DeptAssignment -ProfileId $deptProfile.id -GroupId $group.Id -Label $dept.DisplayName

        [PSCustomObject]@{
            Timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Department  = $dept.DisplayName
            Key         = $dept.Key
            GroupTag    = $dept.GroupTag
            GroupName   = $group.DisplayName
            GroupId     = $group.Id
            ProfileName = $deptProfile.displayName
            ProfileId   = $deptProfile.id
            JoinType    = if ($dept.JoinType) { $dept.JoinType } else { $DefaultJoinType }
            LocalAdmin  = $dept.LocalAdmin
            DryRun      = [bool]$DryRun
        }
    }
    catch {
        $errors += "$($dept.DisplayName) [$($dept.Key)]: $($_.Exception.Message)"
        Write-Host "  [FAILED] $($dept.DisplayName): $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n=== Summary ===" -ForegroundColor Magenta
$results | Format-Table Department, GroupTag, GroupId, ProfileId, JoinType, LocalAdmin -AutoSize

if ($errors.Count -gt 0) {
    Write-Host "`n$($errors.Count) department(s) failed - review before assuming the run is complete:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
}

if (-not $DryRun) {
    $results | Export-Csv -Path $LogPath -NoTypeInformation
    Write-Host "`nLog written to: $LogPath" -ForegroundColor Green
} else {
    Write-Host "`n(No log file written in dry-run mode.)" -ForegroundColor Yellow
}

#endregion =========================================================================
