<#
.SYNOPSIS
    Reports app registration client secrets and certificates expiring
    within N days. This is one of the single most common causes of
    silent, hard-to-diagnose integration outages in M365 environments -
    an app registration's secret quietly expires and whatever depended on
    it (a Power Automate flow, a scheduled script, an SSO integration)
    just stops working with no obvious error pointing back to the cause.

.DESCRIPTION
    Walks every app registration in the tenant, checks both
    passwordCredentials (secrets) and keyCredentials (certs), and flags
    anything expiring inside the threshold window. Also flags anything
    ALREADY expired that nobody noticed.

.PARAMETER WarningThresholdDays
    Number of days out from expiry to flag a credential as "expiring soon"
    (default 30).

.PARAMETER ExportPath
    Path to write the CSV report to.

.PARAMETER AuthMode
    Interactive, AppSecret, or Certificate - passed through to
    Assert-M365Connection. Defaults to Interactive.

.EXAMPLE
    .\Get-AppRegistrationSecretExpiryReport.ps1 -WarningThresholdDays 45

.EXAMPLE
    .\Get-AppRegistrationSecretExpiryReport.ps1 -AuthMode Certificate -ExportPath "C:\Reports\AppRegExpiry.csv"

.NOTES
    Requires Graph scope Application.Read.All.
#>

[CmdletBinding()]
param(
    # ============================================================
    # CONFIGURATION - adjust these values for your environment
    # ============================================================
    # Number of days out from expiry to flag a credential as "expiring soon".
    [int]$WarningThresholdDays = 30,

    # Output path for the CSV report.
    [string]$ExportPath = ".\AppRegSecretExpiry_$(Get-Date -Format 'yyyyMMdd').csv",

    # Auth mode passed through to Assert-M365Connection (Interactive/AppSecret/Certificate).
    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

Write-Host "Scanning app registrations for secret/cert expiry..." -ForegroundColor Cyan
try {
    $apps = Get-MgApplication -All -Property Id,AppId,DisplayName,PasswordCredentials,KeyCredentials
}
catch {
    Write-Error "Failed to retrieve app registrations from Graph: $($_.Exception.Message)"
    return
}

$now = Get-Date
$report = foreach ($app in $apps) {
    foreach ($cred in $app.PasswordCredentials) {
        $daysLeft = ($cred.EndDateTime - $now).Days
        [PSCustomObject]@{
            AppName       = $app.DisplayName
            AppId         = $app.AppId
            CredentialType = "Secret"
            CredentialName = $cred.DisplayName
            ExpiresOn     = $cred.EndDateTime
            DaysRemaining = $daysLeft
            Status        = if ($daysLeft -lt 0) { "EXPIRED" } elseif ($daysLeft -le $WarningThresholdDays) { "EXPIRING_SOON" } else { "OK" }
        }
    }
    foreach ($cred in $app.KeyCredentials) {
        $daysLeft = ($cred.EndDateTime - $now).Days
        [PSCustomObject]@{
            AppName       = $app.DisplayName
            AppId         = $app.AppId
            CredentialType = "Certificate"
            CredentialName = $cred.DisplayName
            ExpiresOn     = $cred.EndDateTime
            DaysRemaining = $daysLeft
            Status        = if ($daysLeft -lt 0) { "EXPIRED" } elseif ($daysLeft -le $WarningThresholdDays) { "EXPIRING_SOON" } else { "OK" }
        }
    }
}

$report | Sort-Object DaysRemaining | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Exported $($report.Count) credential(s) to $ExportPath" -ForegroundColor Green

$urgent = $report | Where-Object { $_.Status -in @("EXPIRED","EXPIRING_SOON") }
if ($urgent) {
    Write-Host "`n=== ACTION NEEDED: $($urgent.Count) credential(s) expired or expiring within $WarningThresholdDays days ===" -ForegroundColor Red
    $urgent | Sort-Object DaysRemaining | Format-Table AppName, CredentialType, ExpiresOn, DaysRemaining, Status -AutoSize
}
else {
    Write-Host "`nNothing expiring within $WarningThresholdDays days. All clear." -ForegroundColor Green
}
