#Requires -Version 5.1
<#
.SYNOPSIS
    Finds Entra ID licenses being paid for but not actually delivering value - assigned to
    disabled accounts, assigned to accounts with no recent sign-in, or sitting unused
    against your purchased seat count per SKU.

.DESCRIPTION
    This is a PORTABLE, VENDOR-NEUTRAL script - it's pure Microsoft Graph, no AD or
    tenant-specific values are hard-coded, and it works as-is against any Entra tenant.

    For every licensed Entra ID user, this script checks:
      - Is the account disabled (AccountEnabled = $false)? A disabled account still
        holding a license is pure waste - this is the single most common finding, usually
        because Offboard-HybridUser-*.ps1's license-removal step didn't run (e.g. an
        older script version, or -SkipLicenseRemoval was used) or ran before this audit
        script existed.
      - Has the account signed in within -InactiveDays? An enabled-but-dormant account
        holding a license is a softer signal than a disabled one, but still worth a look -
        see Audit-StaleAccounts.ps1 for the fuller activity picture on that account.

    It also prints a per-SKU summary (purchased vs. assigned vs. available) so you can see
    at a glance whether you're paying for seats nobody's using, separate from the
    per-user flagging above.

    This is READ-ONLY - it only reports. Once you've reviewed the findings, remove
    licenses either through the M365 admin center or by re-running
    Offboard-HybridUser.ps1 with -CloudOnly against any disabled
    account this flags (that will also revoke sessions and finish the rest of offboarding
    if it wasn't already complete).

.PARAMETER InactiveDays
    Number of days of no Entra sign-in before an enabled, licensed account is flagged as
    a soft waste candidate. Defaults to 90. Disabled accounts are always flagged
    regardless of this value.

.PARAMETER ReportPath
    Folder to write the CSV report and transcript log to. Defaults to .\AuditReports.

.PARAMETER AutoInstallMissingModules
    If a required PSGallery module isn't installed, install it automatically instead
    of prompting.

.EXAMPLE
    .\Audit-LicenseWaste.ps1
    Flags disabled accounts with licenses, and enabled accounts with no sign-in in 90+
    days that still hold a license. Prints a per-SKU purchased/assigned/available summary.

.EXAMPLE
    .\Audit-LicenseWaste.ps1 -InactiveDays 30
    Tighter 30-day threshold for the "enabled but dormant" check.

.NOTES
    Required modules : Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
    Required Graph scopes (delegated or app-only) : User.Read.All, AuditLog.Read.All,
                        Organization.Read.All (Organization.Read.All is what unlocks the
                        per-SKU purchased/available seat summary via Get-MgSubscribedSku;
                        without it, per-user flagging still works but the SKU summary
                        section is skipped and noted as unavailable)

    Sign-in activity relies on the same Entra signInActivity.lastSignInDateTime property
    used by Audit-StaleAccounts.ps1 - see that script's .NOTES for its accuracy/latency
    characteristics. A disabled account is flagged regardless of how recently it signed
    in, since a disabled account cannot sign in again to make use of the license.

    A flagged license isn't automatically safe to remove sight-unseen - confirm the
    account isn't a break-glass/service account or someone on an extended leave who
    still needs the license reserved for their return.
#>

[CmdletBinding()]
param(
    [int]$InactiveDays = 90,

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
# if it's missing and comes from PSGallery, or explaining how to get it if it doesn't.
function Ensure-Module {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ManualInstallHint
    )
    if (Get-Module -ListAvailable -Name $Name) {
        Import-Module -Name $Name -ErrorAction Stop
        return
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
$transcriptFile = Join-Path $ReportPath "AuditLicenseWaste_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $transcriptFile -Append | Out-Null

Write-Host "=== Auditing Entra ID license assignments for waste ===" -ForegroundColor Cyan

#region 1. Load / verify modules and connect
Ensure-Module -Name 'Microsoft.Graph.Users' -ManualInstallHint "Install-Module Microsoft.Graph.Users -Scope CurrentUser"
Ensure-Module -Name 'Microsoft.Graph.Identity.DirectoryManagement' -ManualInstallHint "Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser"

if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "User.Read.All", "AuditLog.Read.All", "Organization.Read.All" -NoWelcome
}
#endregion

#region 2. Per-SKU purchased/assigned/available summary
Write-Host "`n--- License SKU summary ---" -ForegroundColor Cyan
try {
    $skus = Get-MgSubscribedSku -All
    foreach ($sku in $skus) {
        $purchased = $sku.PrepaidUnits.Enabled
        $consumed  = $sku.ConsumedUnits
        $available = $purchased - $consumed
        Write-Host ("  {0,-30} purchased: {1,-5} assigned: {2,-5} available: {3}" -f $sku.SkuPartNumber, $purchased, $consumed, $available)
        Add-Result "n/a" "SKU-Summary:$($sku.SkuPartNumber)" "Info" "Purchased: $purchased, Assigned: $consumed, Available: $available"
    }
}
catch {
    Write-Warning "Could not retrieve SKU summary (requires Organization.Read.All): $($_.Exception.Message)"
    Add-Result "n/a" "SKU-Summary" "Skipped" "Organization.Read.All not granted or Get-MgSubscribedSku failed: $($_.Exception.Message)"
}
#endregion

#region 3. Per-user license waste check
Write-Host "`n--- Per-user license check ---" -ForegroundColor Cyan
$cutoff = (Get-Date).AddDays(-$InactiveDays)
$flaggedCount = 0
$checkedCount = 0

$licensedUsers = Get-MgUser -All -Property Id, UserPrincipalName, AccountEnabled, AssignedLicenses, SignInActivity -Filter "assignedLicenses/`$count ne 0" -ConsistencyLevel eventual -CountVariable licensedCount |
    Where-Object { $_.AssignedLicenses -and $_.AssignedLicenses.Count -gt 0 }

Write-Host "Found $($licensedUsers.Count) licensed user(s) to evaluate.`n"

foreach ($mgUser in $licensedUsers) {
    $checkedCount++
    $upn = $mgUser.UserPrincipalName
    $skuNames = ($mgUser.AssignedLicenses | ForEach-Object { $_.SkuId }) -join ", "

    if (-not $mgUser.AccountEnabled) {
        $flaggedCount++
        Add-Result $upn "License-Waste" "Flagged" "Account is DISABLED but still holds $($mgUser.AssignedLicenses.Count) license(s) (SkuId(s): $skuNames) - candidate for immediate removal"
        continue
    }

    $lastSignIn = $null
    if ($mgUser.SignInActivity -and $mgUser.SignInActivity.LastSignInDateTime) {
        $lastSignIn = [DateTime]$mgUser.SignInActivity.LastSignInDateTime
    }

    if (-not $lastSignIn) {
        Add-Result $upn "License-Waste" "Flagged" "Enabled, licensed, but no recorded sign-in at all - confirm this is an active user before removing the license"
        $flaggedCount++
    }
    elseif ($lastSignIn -lt $cutoff) {
        $daysInactive = [Math]::Round(((Get-Date) - $lastSignIn).TotalDays)
        Add-Result $upn "License-Waste" "Flagged" "Enabled and licensed, but last signed in $daysInactive day(s) ago ($($lastSignIn.ToString('yyyy-MM-dd'))) - review whether the license is still needed"
        $flaggedCount++
    }
    else {
        Add-Result $upn "License-Waste" "OK" "Active within $InactiveDays days ($($lastSignIn.ToString('yyyy-MM-dd')))"
    }
}
#endregion

#region 4. Report
$reportFile = Join-Path $ReportPath "AuditLicenseWaste_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $reportFile -NoTypeInformation

Write-Host "`n=== Audit summary ===" -ForegroundColor Cyan
Write-Host "Licensed users evaluated : $checkedCount"
Write-Host "Flagged as waste         : $flaggedCount"
Write-Host "Full report: $reportFile"
Write-Host "`nDisabled-account flags are safe to act on immediately. Dormant-but-enabled flags need a quick human check first (leave of absence, seasonal role, etc.)." -ForegroundColor Yellow

Stop-Transcript | Out-Null
#endregion
