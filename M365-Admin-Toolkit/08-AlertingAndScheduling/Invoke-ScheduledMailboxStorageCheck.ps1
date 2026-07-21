<#
.SYNOPSIS
    Scheduled-task entry point: runs the mailbox storage report and
    alerts ONLY on mailboxes over threshold. Same silent-on-clean-run
    pattern as the app secret check.

.DESCRIPTION
    This is the script you point Task Scheduler at, not the report script
    itself. It calls Get-MailboxStorageAlert.ps1, inspects the results,
    and only fires Send-M365AdminAlert if one or more mailboxes are over
    the configured percent threshold.

.PARAMETER WarningPercentThreshold
    Percent-of-quota-used threshold above which a mailbox is flagged.
    Passed straight through to Get-MailboxStorageAlert.ps1. Defaults to 85.

.EXAMPLE
    .\Invoke-ScheduledMailboxStorageCheck.ps1
    Run with the default 85% threshold - this is what Task Scheduler runs.

.EXAMPLE
    .\Invoke-ScheduledMailboxStorageCheck.ps1 -WarningPercentThreshold 90
    Run by hand with a looser 90% threshold.

.NOTES
    Requires ExchangeOnline connected (app-only/cert auth recommended -
    see 00-Setup\Connect-M365Services.ps1).
#>

[CmdletBinding()]
param(
    [int]$WarningPercentThreshold = 85
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$Config = @{
    # Path to the report script this wrapper calls, in 07-EnvironmentHealthAutomation.
    ReportScriptPath  = "$PSScriptRoot\..\07-EnvironmentHealthAutomation\Get-MailboxStorageAlert.ps1"

    # Path to the shared connection helper (dot-sourced for Assert-M365Connection/Disconnect-M365).
    ConnectScriptPath = "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"

    # Rolling log file for every run of this check, clean or not.
    LogPath           = "$PSScriptRoot\Logs\MailboxStorageCheck.log"

    # Folder where each run's timestamped CSV export is written.
    ReportExportDir   = "$PSScriptRoot\Logs\Reports"

    # Auth mode used for the unattended Exchange Online connection -
    # Interactive won't work under Task Scheduler, use Certificate or AppSecret.
    AuthMode          = "Certificate"
}

New-Item -ItemType Directory -Path (Split-Path $Config.LogPath) -Force | Out-Null
New-Item -ItemType Directory -Path $Config.ReportExportDir -Force | Out-Null
function Write-Log { param($msg) "$(Get-Date -Format 'u') - $msg" | Out-File -Append -FilePath $Config.LogPath }

. $Config.ConnectScriptPath
. "$PSScriptRoot\Send-M365AdminAlert.ps1"

try {
    Assert-M365Connection -Services ExchangeOnline -AuthMode $Config.AuthMode
    Write-Log "Connected to Exchange Online."

    $exportPath = Join-Path $Config.ReportExportDir "MailboxStorage_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    & $Config.ReportScriptPath -WarningPercentThreshold $WarningPercentThreshold -ExportPath $exportPath

    $results = Import-Csv $exportPath
    $warn = $results | Where-Object { $_.Flag -eq "WARNING" }

    if ($warn) {
        $bodyLines = $warn | Sort-Object PercentUsed -Descending | ForEach-Object {
            "$($_.DisplayName) ($($_.UPN)) - $($_.UsedGB)GB / $($_.QuotaGB)GB ($($_.PercentUsed)%)"
        }
        $body = "$($warn.Count) mailbox(es) over $WarningPercentThreshold% quota:`n`n" + ($bodyLines -join "`n")

        Send-M365AdminAlert -Subject "Mailbox storage warning ($($warn.Count) mailbox(es))" `
            -Body $body -Severity Warning

        Write-Log "ALERT SENT - $($warn.Count) mailbox(es) over threshold."
    }
    else {
        Write-Log "Clean run - no mailboxes over $WarningPercentThreshold%. No alert sent."
    }
}
catch {
    Write-Log "ERROR: $_"
    Send-M365AdminAlert -Subject "Mailbox storage check FAILED to run" -Body "$_" -Severity Critical
}
finally {
    Disconnect-M365
}
