#Requires -Version 5.1
<#
.SYNOPSIS
    Audits membership of your highest-privilege AD groups and Entra ID directory roles,
    and flags any privileged account that's disabled/stale or has no MFA method
    registered - the accounts where a gap actually matters most.

.DESCRIPTION
    This is a PORTABLE, VENDOR-NEUTRAL script - the AD group names and Entra role names
    it checks are configurable parameters with sensible built-in defaults (Domain Admins/
    Enterprise Admins/Schema Admins on the AD side, Global Administrator/User
    Administrator/License Administrator/Privileged Role Administrator on the Entra side),
    nothing tenant-specific is hard-coded.

    For every member of the AD groups in -AdPrivilegedGroups, this script checks:
      - Is the AD account disabled? A disabled account in a privileged group is
        low-risk but worth cleaning up (shouldn't be sitting in Domain Admins at all).
      - Has it been inactive per the same logic as Audit-StaleAccounts.ps1? A stale
        privileged account is a bigger risk than a stale ordinary account - it's a more
        valuable target if the credentials ever leak.

    For every assignment to the Entra ID directory roles in -EntraPrivilegedRoles, this
    script checks:
      - Is the account disabled?
      - Does the account have at least one MFA method registered (via Microsoft Graph
        authentication methods)? A privileged role holder with no MFA is the single
        highest-value finding this script can produce - it means a compromised password
        alone is enough to take over a Global Admin (or similar) account.
      - Is the account a guest (external) user? Worth a second look regardless of MFA
        status - external accounts holding privileged roles are unusual and often
        forgotten from a one-off project.

    This is READ-ONLY - it only reports. It does not remove anyone from a group or role,
    since privileged access changes are exactly the kind of thing that should always be a
    deliberate, reviewed action.

.PARAMETER AdPrivilegedGroups
    AD group names to audit membership of. Defaults to Domain Admins, Enterprise Admins,
    Schema Admins. Pass your own list to include custom-built admin/tier-0 groups too.

.PARAMETER EntraPrivilegedRoles
    Entra ID directory role display names to audit. Defaults to Global Administrator,
    Privileged Role Administrator, User Administrator, License Administrator. Pass your
    own list to cover additional roles (e.g. Exchange Administrator, Security
    Administrator) relevant to your environment.

.PARAMETER InactiveDays
    Number of days of no activity before a privileged account is flagged as stale, using
    the same AD-LastLogonTimestamp-vs-Entra-signInActivity comparison as
    Audit-StaleAccounts.ps1. Defaults to 60 (tighter than the general 90-day default,
    since privileged accounts warrant closer attention).

.PARAMETER ReportPath
    Folder to write the CSV report and transcript log to. Defaults to .\AuditReports.

.PARAMETER AutoInstallMissingModules
    If a required PSGallery module isn't installed, install it automatically instead
    of prompting. The ActiveDirectory module (RSAT) can never be auto-installed this way.

.EXAMPLE
    .\Audit-PrivilegedAccess.ps1
    Audits the default AD privileged groups and Entra privileged roles.

.EXAMPLE
    .\Audit-PrivilegedAccess.ps1 -EntraPrivilegedRoles "Global Administrator", "Exchange Administrator", "Security Administrator"
    Audits a custom set of Entra roles instead of the built-in default list.

.NOTES
    Required modules  : ActiveDirectory, Microsoft.Graph.Users,
                         Microsoft.Graph.Identity.DirectoryManagement,
                         Microsoft.Graph.Identity.SignIns
    Required Graph scopes (delegated or app-only) :
                         User.Read.All, AuditLog.Read.All, RoleManagement.Read.Directory,
                         UserAuthenticationMethod.Read.All

    MFA CHECK CAVEAT: this checks whether the user has ANY authentication method
    registered beyond a password (Get-MgUserAuthenticationMethod). It cannot tell you
    whether Conditional Access or per-user MFA is actually *enforced* for that account -
    a registered method just means MFA is possible for them, not necessarily required on
    every sign-in. Cross-check flagged accounts against your Conditional Access policies
    if you need to confirm enforcement, not just registration.

    A flagged AD group membership or Entra role assignment is not automatically wrong -
    some service/automation accounts legitimately need standing privileged access. The
    point of this audit is to make sure that's a deliberate, reviewed state rather than
    something nobody's looked at recently.
#>

[CmdletBinding()]
param(
    [string[]]$AdPrivilegedGroups = @('Domain Admins', 'Enterprise Admins', 'Schema Admins'),

    [string[]]$EntraPrivilegedRoles = @('Global Administrator', 'Privileged Role Administrator', 'User Administrator', 'License Administrator'),

    [int]$InactiveDays = 60,

    [string]$ReportPath = ".\AuditReports",

    [switch]$AutoInstallMissingModules
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[Object]

function Add-Result {
    param($User, $Category, $Status, $Detail = "")
    $results.Add([PSCustomObject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        User      = $User
        Category  = $Category
        Status    = $Status
        Detail    = $Detail
    })
}

# Ensures a required module is available, importing it if present, offering to install it
# if it's missing and comes from PSGallery, or explaining how to get it if it doesn't
# (currently only ActiveDirectory/RSAT, which is a Windows feature, not a gallery module).
function Ensure-Module {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ManualInstallHint,
        [switch]$IsWindowsFeature
    )
    if (Get-Module -ListAvailable -Name $Name) {
        Import-Module -Name $Name -ErrorAction Stop
        return
    }
    if ($IsWindowsFeature) {
        throw "Required module '$Name' isn't installed, and it can't be installed from PSGallery - it comes from RSAT. $ManualInstallHint"
    }
    Write-Warning "Required module '$Name' is not installed."
    $doInstall = $AutoInstallMissingModules -or $PSCmdlet.ShouldContinue(
        "Install '$Name' now from PSGallery for the current user?", "Missing module: $Name")
    if (-not $doInstall) {
        throw "'$Name' is required but not installed. $ManualInstallHint"
    }
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
        }
        $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Import-Module -Name $Name -ErrorAction Stop
    }
    catch {
        throw "Failed to install '$Name' automatically: $($_.Exception.Message) $ManualInstallHint"
    }
}

if (-not (Test-Path $ReportPath)) {
    New-Item -Path $ReportPath -ItemType Directory -Force | Out-Null
}
$transcriptFile = Join-Path $ReportPath "AuditPrivilegedAccess_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $transcriptFile -Append | Out-Null

Write-Host "=== Auditing privileged AD groups and Entra directory roles ===" -ForegroundColor Cyan

#region 1. Load / verify modules and connect
Ensure-Module -Name 'ActiveDirectory' -IsWindowsFeature -ManualInstallHint (
    "Windows 10/11: Settings > Optional Features > Add a feature > 'RSAT: Active Directory " +
    "Domain Services and Lightweight Directory Tools' (or run, as admin: " +
    "Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0). " +
    "Windows Server: Install-WindowsFeature RSAT-AD-PowerShell."
)
Ensure-Module -Name 'Microsoft.Graph.Users' -ManualInstallHint "Install-Module Microsoft.Graph.Users -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Identity.DirectoryManagement' -ManualInstallHint "Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Identity.SignIns' -ManualInstallHint "Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser"

if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "User.Read.All", "AuditLog.Read.All", "RoleManagement.Read.Directory", "UserAuthenticationMethod.Read.All" -NoWelcome
}
#endregion

$cutoff = (Get-Date).AddDays(-$InactiveDays)

#region 2. Audit AD privileged groups
Write-Host "`n--- AD privileged group membership ---" -ForegroundColor Cyan
foreach ($groupName in $AdPrivilegedGroups) {
    try {
        $members = Get-ADGroupMember -Identity $groupName -Recursive -ErrorAction Stop | Where-Object { $_.objectClass -eq 'user' }
    }
    catch {
        Add-Result $groupName "AD-Group-Lookup" "Failed" "Could not enumerate '$groupName': $($_.Exception.Message)"
        continue
    }
    Write-Host "  $groupName - $($members.Count) member(s)"
    foreach ($m in $members) {
        try {
            $adUser = Get-ADUser -Identity $m.SamAccountName -Properties Enabled, LastLogonTimestamp, UserPrincipalName
        }
        catch {
            Add-Result $m.SamAccountName "AD-Privileged:$groupName" "Failed" "Could not look up member details: $($_.Exception.Message)"
            continue
        }
        if (-not $adUser.Enabled) {
            Add-Result $adUser.SamAccountName "AD-Privileged:$groupName" "Flagged" "Member of '$groupName' but the AD account is DISABLED - should be removed from the group"
            continue
        }
        $adLastLogon = if ($adUser.LastLogonTimestamp) { [DateTime]::FromFileTime($adUser.LastLogonTimestamp) } else { $null }
        if (-not $adLastLogon -or $adLastLogon -lt $cutoff) {
            $ageText = if ($adLastLogon) { "last AD logon $($adLastLogon.ToString('yyyy-MM-dd'))" } else { "no recorded AD logon" }
            Add-Result $adUser.SamAccountName "AD-Privileged:$groupName" "Flagged" "Member of '$groupName', enabled, but stale ($ageText, threshold $InactiveDays days) - confirm this account still needs standing privileged access"
        }
        else {
            Add-Result $adUser.SamAccountName "AD-Privileged:$groupName" "OK" "Active member, last AD logon $($adLastLogon.ToString('yyyy-MM-dd'))"
        }
    }
}
#endregion

#region 3. Audit Entra directory role assignments
Write-Host "`n--- Entra ID directory role assignments ---" -ForegroundColor Cyan
foreach ($roleName in $EntraPrivilegedRoles) {
    try {
        $roleDef = Get-MgDirectoryRole -Filter "displayName eq '$roleName'" -ErrorAction SilentlyContinue
        if (-not $roleDef) {
            # Role may not be activated in this tenant yet (Entra only instantiates a
            # directory role object the first time it's assigned) - not an error.
            Add-Result $roleName "Entra-Role-Lookup" "Info" "Role '$roleName' has no active directory role object in this tenant (never assigned, or not yet activated) - nothing to audit"
            continue
        }
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $roleDef.Id -All
    }
    catch {
        Add-Result $roleName "Entra-Role-Lookup" "Failed" "Could not enumerate '$roleName': $($_.Exception.Message)"
        continue
    }
    Write-Host "  $roleName - $($members.Count) member(s)"
    foreach ($m in $members) {
        if ($m.AdditionalProperties['@odata.type'] -ne '#microsoft.graph.user') {
            # Skip service principals / groups assigned the role - only auditing human accounts here.
            continue
        }
        $userId  = $m.Id
        $mgUser  = Get-MgUser -UserId $userId -Property Id, UserPrincipalName, AccountEnabled, UserType, SignInActivity -ErrorAction SilentlyContinue
        if (-not $mgUser) {
            Add-Result $userId "Entra-Privileged:$roleName" "Failed" "Could not resolve member details for object Id $userId"
            continue
        }
        $upn = $mgUser.UserPrincipalName

        if (-not $mgUser.AccountEnabled) {
            Add-Result $upn "Entra-Privileged:$roleName" "Flagged" "Assigned '$roleName' but the account is DISABLED - remove the role assignment"
            continue
        }

        if ($mgUser.UserType -eq 'Guest') {
            Add-Result $upn "Entra-Privileged:$roleName" "Flagged" "Assigned '$roleName' and is a GUEST (external) account - confirm this is still an intentional, needed assignment"
        }

        $lastSignIn = $null
        if ($mgUser.SignInActivity -and $mgUser.SignInActivity.LastSignInDateTime) {
            $lastSignIn = [DateTime]$mgUser.SignInActivity.LastSignInDateTime
        }
        if (-not $lastSignIn -or $lastSignIn -lt $cutoff) {
            $ageText = if ($lastSignIn) { "last sign-in $($lastSignIn.ToString('yyyy-MM-dd'))" } else { "no recorded sign-in" }
            Add-Result $upn "Entra-Privileged:$roleName" "Flagged" "Assigned '$roleName', enabled, but stale ($ageText, threshold $InactiveDays days)"
        }

        try {
            $authMethods = Get-MgUserAuthenticationMethod -UserId $userId -ErrorAction Stop
            # A password is always present as a "method" - anything beyond that count
            # means at least one real MFA factor (authenticator app, phone, FIDO2, etc.)
            # is registered.
            $mfaMethods = $authMethods | Where-Object { $_.AdditionalProperties['@odata.type'] -ne '#microsoft.graph.passwordAuthenticationMethod' }
            if (-not $mfaMethods -or $mfaMethods.Count -eq 0) {
                Add-Result $upn "Entra-Privileged:$roleName" "Flagged" "Assigned '$roleName' with NO MFA method registered - highest-priority finding in this report, remediate first"
            }
            else {
                Add-Result $upn "Entra-Privileged:$roleName" "OK" "Has $($mfaMethods.Count) MFA method(s) registered"
            }
        }
        catch {
            Add-Result $upn "Entra-Privileged:$roleName" "Failed" "Could not check MFA methods (requires UserAuthenticationMethod.Read.All): $($_.Exception.Message)"
        }
    }
}
#endregion

#region 4. Report
$reportFile = Join-Path $ReportPath "AuditPrivilegedAccess_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $reportFile -NoTypeInformation

$flagged = $results | Where-Object { $_.Status -eq 'Flagged' }
$noMfaFlags = $flagged | Where-Object { $_.Detail -like "*NO MFA*" }

Write-Host "`n=== Audit summary ===" -ForegroundColor Cyan
Write-Host "Total findings flagged : $($flagged.Count)"
Write-Host "No-MFA privileged accounts : $($noMfaFlags.Count) <- review these first"
Write-Host "Full report: $reportFile"

Stop-Transcript | Out-Null
#endregion
