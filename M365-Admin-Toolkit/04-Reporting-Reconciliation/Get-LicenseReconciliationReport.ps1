<#
.SYNOPSIS
    Reconciles license assignments against active/inactive status to find
    wasted spend: licensed-but-disabled accounts, licensed-but-no-signin
    accounts, and unlicensed-but-enabled accounts.

.DESCRIPTION
    Pulls all users + their licenses + last sign-in activity via Graph's
    signInActivity property (requires AuditLog.Read.All), cross-references
    against tenant SKU consumption, and flags likely waste. Also reports
    unused/available seats per SKU so you can see at a glance which
    subscriptions have more seats purchased than assigned.

.PARAMETER InactiveThresholdDays
    Number of days since last sign-in before a licensed account is
    considered inactive (and therefore likely wasted spend). Defaults to
    the value in the CONFIGURATION block.

.PARAMETER ExportPath
    Path to write the CSV report to. Defaults to the value in the
    CONFIGURATION block.

.PARAMETER AuthMode
    Authentication mode passed to Assert-M365Connection: Interactive,
    AppSecret, or Certificate.

.EXAMPLE
    .\Get-LicenseReconciliationReport.ps1

    Runs with the default threshold and export path defined in the
    CONFIGURATION block below.

.EXAMPLE
    .\Get-LicenseReconciliationReport.ps1 -InactiveThresholdDays 45 -AuthMode AppSecret

    Flags licensed accounts with no sign-in in the last 45 days, using
    app-only auth for an unattended/scheduled run.

.NOTES
    signInActivity requires an Entra ID P1/P2 license on the tenant and the
    AuditLog.Read.All Graph scope.
#>

[CmdletBinding()]
param(
    [int]$InactiveThresholdDays,
    [string]$ExportPath,

    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Number of days since last sign-in before a licensed account is flagged as likely waste.
$DefaultInactiveThresholdDays = 60
# Folder/file path where the CSV report is written (default: script folder, dated filename).
$DefaultExportPath = ".\LicenseReconciliation_$(Get-Date -Format 'yyyyMMdd').csv"
# SKU part numbers to exclude from waste-flagging entirely (e.g. free/trial SKUs you don't care about reconciling). Leave empty to include all SKUs.
$ExcludedSkuPartNumbers = @()
# Minimum number of unused/available seats on a SKU before it's called out as a candidate for reducing your license count.
$MinUnusedSeatThreshold = 5

if (-not $PSBoundParameters.ContainsKey('InactiveThresholdDays')) { $InactiveThresholdDays = $DefaultInactiveThresholdDays }
if (-not $PSBoundParameters.ContainsKey('ExportPath')) { $ExportPath = $DefaultExportPath }

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

Write-Host "Pulling all users with license and sign-in activity..." -ForegroundColor Cyan

try {
    $users = Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,AccountEnabled,AssignedLicenses,SignInActivity
    $skus = Get-MgSubscribedSku
}
catch {
    Write-Error "Failed to retrieve users/SKUs from Graph: $_"
    return
}

$skuLookup = @{}
$skus | ForEach-Object { $skuLookup[$_.SkuId] = $_.SkuPartNumber }

$cutoff = (Get-Date).AddDays(-$InactiveThresholdDays)

$report = foreach ($u in $users) {
    $licenseNames = $u.AssignedLicenses.SkuId | ForEach-Object { $skuLookup[$_] } | Where-Object { $_ -notin $ExcludedSkuPartNumbers }
    $lastSignIn = $u.SignInActivity.LastSignInDateTime
    $isInactive = (-not $lastSignIn) -or ($lastSignIn -lt $cutoff)

    $flag = if (-not $u.AccountEnabled -and $licenseNames) {
        "DISABLED_BUT_LICENSED"
    } elseif ($u.AccountEnabled -and $licenseNames -and $isInactive) {
        "LICENSED_BUT_INACTIVE"
    } elseif ($u.AccountEnabled -and -not $licenseNames) {
        "ENABLED_BUT_UNLICENSED"
    } else {
        "OK"
    }

    [PSCustomObject]@{
        DisplayName     = $u.DisplayName
        UPN             = $u.UserPrincipalName
        AccountEnabled  = $u.AccountEnabled
        Licenses        = ($licenseNames -join "; ")
        LastSignIn      = $lastSignIn
        Flag            = $flag
    }
}

$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Exported full report to $ExportPath" -ForegroundColor Green

$wasteRows = $report | Where-Object { $_.Flag -in @("DISABLED_BUT_LICENSED","LICENSED_BUT_INACTIVE") }
Write-Host "`n=== Likely license waste ($($wasteRows.Count) accounts) ===" -ForegroundColor Yellow
$wasteRows | Format-Table DisplayName, UPN, Flag, Licenses, LastSignIn -AutoSize

# Unused-seat summary per SKU - surfaces subscriptions where purchased seats exceed assigned seats
$seatSummary = foreach ($sku in $skus) {
    $enabled = $sku.PrepaidUnits.Enabled
    $consumed = $sku.ConsumedUnits
    $unused = $enabled - $consumed
    if ($unused -ge $MinUnusedSeatThreshold) {
        [PSCustomObject]@{
            SkuPartNumber = $sku.SkuPartNumber
            Enabled       = $enabled
            Consumed      = $consumed
            Unused        = $unused
        }
    }
}
if ($seatSummary) {
    Write-Host "`n=== SKUs with $MinUnusedSeatThreshold+ unused seats ===" -ForegroundColor Yellow
    $seatSummary | Format-Table -AutoSize
}
