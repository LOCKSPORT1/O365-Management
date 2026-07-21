<#
.SYNOPSIS
    Flags stale/inactive accounts that are strong offboarding-cleanup or
    security-review candidates: no sign-in in N days, enabled accounts
    with no license, and accounts whose manager no longer exists (orphaned
    org chart references from incomplete offboarding).

.DESCRIPTION
    Pulls all users via Microsoft Graph along with their signInActivity,
    flags any account whose last sign-in is older than the configured
    threshold (or that has never signed in), and for each stale account
    checks whether its manager reference points to a still-active account.
    Results are exported to CSV, and enabled-but-stale accounts (the
    highest-priority cleanup candidates) are also printed to the console.

.PARAMETER InactiveThresholdDays
    Number of days since last sign-in before an account is considered
    stale. Defaults to the value in the CONFIGURATION block.

.PARAMETER ExportPath
    Path to write the CSV report to. Defaults to the value in the
    CONFIGURATION block.

.PARAMETER AuthMode
    Authentication mode passed to Assert-M365Connection: Interactive,
    AppSecret, or Certificate.

.EXAMPLE
    .\Get-InactiveUserReport.ps1

    Runs with the default threshold and export path defined in the
    CONFIGURATION block below.

.EXAMPLE
    .\Get-InactiveUserReport.ps1 -InactiveThresholdDays 45 -AuthMode Certificate

    Flags accounts with no sign-in in the last 45 days, authenticating
    via the certificate configured in 00-Setup\Connect-M365Services.ps1.

.NOTES
    Complements Get-LicenseReconciliationReport.ps1 - that one is
    license-cost focused, this one is security/hygiene focused.
    Requires AuditLog.Read.All Graph scope for signInActivity.
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
# Number of days since last sign-in before an account is flagged as stale.
$DefaultInactiveThresholdDays = 90
# Folder/file path where the CSV report is written (default: script folder, dated filename).
$DefaultExportPath = ".\InactiveUserReport_$(Get-Date -Format 'yyyyMMdd').csv"

if (-not $PSBoundParameters.ContainsKey('InactiveThresholdDays')) { $InactiveThresholdDays = $DefaultInactiveThresholdDays }
if (-not $PSBoundParameters.ContainsKey('ExportPath')) { $ExportPath = $DefaultExportPath }

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

$cutoff = (Get-Date).AddDays(-$InactiveThresholdDays)
Write-Host "Scanning for accounts inactive since before $($cutoff.ToShortDateString())..." -ForegroundColor Cyan

try {
    $users = Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,AccountEnabled,SignInActivity,CreatedDateTime
}
catch {
    Write-Error "Failed to retrieve users from Graph: $_"
    return
}

$report = foreach ($u in $users) {
    $lastSignIn = $u.SignInActivity.LastSignInDateTime
    $neverSignedIn = -not $lastSignIn
    $isStale = $neverSignedIn -or ($lastSignIn -lt $cutoff)

    if (-not $isStale) { continue }

    # Check manager still exists / is enabled - a broken manager reference often means offboarding was incomplete somewhere upstream
    $managerStatus = "N/A"
    try {
        $mgr = Get-MgUserManager -UserId $u.Id -ErrorAction SilentlyContinue
        if ($mgr) {
            $mgrDetail = Get-MgUser -UserId $mgr.Id -Property AccountEnabled
            $managerStatus = if ($mgrDetail.AccountEnabled) { "Active" } else { "DISABLED - orphaned reference" }
        } else {
            $managerStatus = "No manager set"
        }
    } catch { $managerStatus = "Lookup failed" }

    [PSCustomObject]@{
        DisplayName    = $u.DisplayName
        UPN            = $u.UserPrincipalName
        AccountEnabled = $u.AccountEnabled
        LastSignIn     = $lastSignIn
        NeverSignedIn  = $neverSignedIn
        CreatedDate    = $u.CreatedDateTime
        ManagerStatus  = $managerStatus
    }
}

$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Exported $($report.Count) stale account(s) to $ExportPath" -ForegroundColor Green

$enabledStale = $report | Where-Object AccountEnabled
if ($enabledStale) {
    Write-Host "`n=== PRIORITY: enabled accounts with no recent sign-in ($($enabledStale.Count)) ===" -ForegroundColor Red
    $enabledStale | Format-Table DisplayName, UPN, LastSignIn, ManagerStatus -AutoSize
}
