<#
.SYNOPSIS
    Assigns M365 licenses and group memberships based on department, and
    sets usage location. Designed to be called standalone OR from
    New-M365UserOnboarding.ps1.

.DESCRIPTION
    Maps Department -> License SKU(s) + Security Groups via a lookup table
    you maintain in the Config block below. This keeps "who gets what" out
    of code logic and in one easy-to-edit table.

.PARAMETER UserId
    Entra ID object ID or UPN of the user to license/group.

.PARAMETER Department
    Department name used to look up licenses/groups in the $DepartmentLicenseMap
    and $DepartmentGroupMap tables in the Configuration block below. Falls back
    to the "Default" entry if Department doesn't match a key.

.PARAMETER AdditionalGroups
    Extra security group display names to add on top of whatever the
    Department mapping resolves to (e.g. baseline/all-staff groups passed in
    by New-M365UserOnboarding.ps1).

.PARAMETER UsageLocation
    ISO country code to set on the user before license assignment. Required -
    Graph will reject license assignment without a usage location.

.PARAMETER AuthMode
    Interactive, AppSecret, or Certificate - passed through to
    Assert-M365Connection / Connect-M365Services.ps1. Defaults to Interactive.

.EXAMPLE
    .\Add-UserToGroupsAndLicenses.ps1 -UserId "jane.doe@yourdomain.com" -Department "Engineering"

    Sets usage location, then assigns the Engineering department's licenses
    and security groups to Jane Doe.

.EXAMPLE
    .\Add-UserToGroupsAndLicenses.ps1 -UserId "jane.doe@yourdomain.com" -Department "Sales" `
        -AdditionalGroups "SG-AllStaff","SG-VPN-Users" -UsageLocation "GB"

    Assigns Sales department licenses/groups plus two extra baseline groups,
    using a non-default usage location.

.NOTES
    Run Get-MgSubscribedSku to list your tenant's actual SKU part numbers -
    the ones below are common examples and WILL need to match your tenant.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UserId,          # Entra object ID or UPN
    [Parameter(Mandatory)][string]$Department,
    [string[]]$AdditionalGroups = @(),
    [string]$UsageLocation = "US",

    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Department -> license SKU part number(s) to assign.
# Run: Get-MgSubscribedSku | Select SkuPartNumber, SkuId  to find your tenant's actual values.
$DepartmentLicenseMap = @{
    "Sales"        = @("SPE_E3")
    "Engineering"  = @("SPE_E3", "PROJECTPREMIUM")
    "Production"   = @("O365_BUSINESS_ESSENTIALS")
    "Finance"      = @("SPE_E3")
    # Fallback license(s) applied when Department doesn't match a key above
    "Default"      = @("SPE_E3")
}

# Department -> security group display name(s) to add the user to.
$DepartmentGroupMap = @{
    "Sales"        = @("SG-Sales", "SG-CRM-Users")
    "Engineering"  = @("SG-Engineering", "SG-Autodesk-Users", "SG-Bluebeam-Users")
    "Production"   = @("SG-Production")
    "Finance"      = @("SG-Finance", "SG-Finance-App")
    # Fallback group(s) applied when Department doesn't match a key above
    "Default"      = @()
}
# ============================================================

# Resolve usage location first - required before license assignment will succeed
try {
    Update-MgUser -UserId $UserId -UsageLocation $UsageLocation -ErrorAction Stop
    Write-Host "Usage location set to $UsageLocation" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to set usage location for $UserId - $($_.Exception.Message)"
}

# License assignment
$skuNames = if ($DepartmentLicenseMap.ContainsKey($Department)) { $DepartmentLicenseMap[$Department] } else { $DepartmentLicenseMap["Default"] }
$allSkus = Get-MgSubscribedSku

foreach ($skuName in $skuNames) {
    $sku = $allSkus | Where-Object { $_.SkuPartNumber -eq $skuName }
    if (-not $sku) {
        Write-Warning "SKU '$skuName' not found in tenant subscriptions - skipping. Check Get-MgSubscribedSku output."
        continue
    }
    $available = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
    if ($available -le 0) {
        Write-Warning "SKU '$skuName' has 0 available licenses. Assign manually or free one up."
        continue
    }
    try {
        Set-MgUserLicense -UserId $UserId -AddLicenses @(@{SkuId = $sku.SkuId}) -RemoveLicenses @() -ErrorAction Stop
        Write-Host "Assigned license: $skuName" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to assign license '$skuName' to $UserId - $($_.Exception.Message)"
    }
}

# Group assignment
$groupNames = @()
$groupNames += if ($DepartmentGroupMap.ContainsKey($Department)) { $DepartmentGroupMap[$Department] } else { $DepartmentGroupMap["Default"] }
$groupNames += $AdditionalGroups

foreach ($groupName in ($groupNames | Select-Object -Unique)) {
    $group = Get-MgGroup -Filter "displayName eq '$groupName'"
    if (-not $group) {
        Write-Warning "Group '$groupName' not found - skipping."
        continue
    }
    try {
        New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $UserId
        Write-Host "Added to group: $groupName" -ForegroundColor Green
    }
    catch {
        if ($_.Exception.Message -match "already exist") {
            Write-Host "Already a member of: $groupName" -ForegroundColor Yellow
        } else {
            Write-Warning "Failed to add to $groupName - $($_.Exception.Message)"
        }
    }
}

Write-Host "License and group assignment complete for user $UserId." -ForegroundColor Cyan
