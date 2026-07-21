<#
.SYNOPSIS
    Scheduled-task entry point: runs the app registration secret/cert
    expiry report and sends an alert ONLY if something is expired or
    expiring soon. Designed to be silent on a clean run - you shouldn't
    get an email every day telling you nothing's wrong.

.DESCRIPTION
    This is the script you point Task Scheduler at, not the report script
    itself. It calls Get-AppRegistrationSecretExpiryReport.ps1, inspects
    the results, and only fires Send-M365AdminAlert if there's something
    urgent - keeps signal-to-noise high so alerts actually get read.

.PARAMETER WarningThresholdDays
    Number of days out to treat a secret/certificate as "expiring soon".
    Passed straight through to Get-AppRegistrationSecretExpiryReport.ps1.
    Defaults to 30.

.EXAMPLE
    .\Invoke-ScheduledAppSecretExpiryCheck.ps1
    Run with the default 30-day threshold - this is what Task Scheduler runs.

.EXAMPLE
    .\Invoke-ScheduledAppSecretExpiryCheck.ps1 -WarningThresholdDays 14
    Run by hand with a tighter 14-day threshold to test alerting.

.NOTES
    Requires Graph connected (app-only/cert auth recommended for
    unattended runs - see 00-Setup\Connect-M365Services.ps1).
    Logs every run (clean or not) to a rolling log file regardless of
    whether an alert fired, so you have an audit trail of "did this even
    run last Tuesday."
#>

[CmdletBinding()]
param(
    [int]$WarningThresholdDays = 30
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$Config = @{
    # Path to the report script this wrapper calls, in 07-EnvironmentHealthAutomation.
    ReportScriptPath  = "$PSScriptRoot\..\07-EnvironmentHealthAutomation\Get-AppRegistrationSecretExpiryReport.ps1"

    # Path to the shared connection helper (dot-sourced for Assert-M365Connection/Disconnect-M365).
    ConnectScriptPath = "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"

    # Rolling log file for every run of this check, clean or not.
    LogPath           = "$PSScriptRoot\Logs\AppSecretExpiryCheck.log"

    # Folder where each run's timestamped CSV export is written.
    ReportExportDir   = "$PSScriptRoot\Logs\Reports"

    # Auth mode used for the unattended Graph connection - Interactive won't
    # work under Task Scheduler, use Certificate or AppSecret.
    AuthMode          = "Certificate"
}

New-Item -ItemType Directory -Path (Split-Path $Config.LogPath) -Force | Out-Null
New-Item -ItemType Directory -Path $Config.ReportExportDir -Force | Out-Null
function Write-Log { param($msg) "$(Get-Date -Format 'u') - $msg" | Out-File -Append -FilePath $Config.LogPath }

. $Config.ConnectScriptPath
. "$PSScriptRoot\Send-M365AdminAlert.ps1"

try {
    Assert-M365Connection -Services Graph -AuthMode $Config.AuthMode
    Write-Log "Connected to Graph."

    $exportPath = Join-Path $Config.ReportExportDir "AppSecretExpiry_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    & $Config.ReportScriptPath -WarningThresholdDays $WarningThresholdDays -ExportPath $exportPath

    $results = Import-Csv $exportPath
    $urgent = $results | Where-Object { $_.Status -in @("EXPIRED","EXPIRING_SOON") }

    if ($urgent) {
        $expiredCount = ($urgent | Where-Object Status -eq "EXPIRED").Count
        $soonCount = ($urgent | Where-Object Status -eq "EXPIRING_SOON").Count
        $severity = if ($expiredCount -gt 0) { "Critical" } else { "Warning" }

        $bodyLines = $urgent | Sort-Object DaysRemaining | ForEach-Object {
            "$($_.AppName) [$($_.CredentialType)] - expires $($_.ExpiresOn) ($($_.DaysRemaining) days)"
        }
        $body = "$expiredCount already expired, $soonCount expiring within $WarningThresholdDays days:`n`n" + ($bodyLines -join "`n")

        Send-M365AdminAlert -Subject "App registration credentials need attention ($($urgent.Count))" `
            -Body $body -Severity $severity

        Write-Log "ALERT SENT - $($urgent.Count) credential(s) flagged ($expiredCount expired, $soonCount expiring soon)."
    }
    else {
        Write-Log "Clean run - no credentials expiring within $WarningThresholdDays days. No alert sent."
    }
}
catch {
    Write-Log "ERROR: $_"
    Send-M365AdminAlert -Subject "App secret expiry check FAILED to run" -Body "$_" -Severity Critical
}
finally {
    Disconnect-M365
}
