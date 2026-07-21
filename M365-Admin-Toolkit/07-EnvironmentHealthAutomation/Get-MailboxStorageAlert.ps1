<#
.SYNOPSIS
    Flags mailboxes approaching their storage quota before users start
    getting bounce/send failures - the classic "why can't I send email"
    ticket that's almost always a full mailbox nobody was watching.

.DESCRIPTION
    Pulls mailbox size and quota for every user mailbox, calculates
    percentage used, and flags anything over the warning threshold.
    Covers both primary mailbox and, optionally, archive size.

.PARAMETER WarningPercentThreshold
    Percentage of quota used at which a mailbox is flagged (default 85).

.PARAMETER IncludeArchive
    Also pulls archive mailbox size for context (does not factor into the
    percentage-used calculation, which is primary mailbox only).

.PARAMETER ExportPath
    Path to write the CSV report to.

.PARAMETER AuthMode
    Interactive, AppSecret, or Certificate - passed through to
    Assert-M365Connection. Defaults to Interactive.

.EXAMPLE
    .\Get-MailboxStorageAlert.ps1 -WarningPercentThreshold 80 -IncludeArchive

.NOTES
    Self-connects to Exchange Online automatically if not already connected
    (see -AuthMode param; defaults to Interactive). No manual dot-sourcing
    required - Connect-M365Services.ps1 is called internally.
#>

[CmdletBinding()]
param(
    # ============================================================
    # CONFIGURATION - adjust these values for your environment
    # ============================================================
    # Percentage of quota used at which a mailbox is flagged as a warning.
    [int]$WarningPercentThreshold = 85,

    # Also pull archive mailbox size for context.
    [switch]$IncludeArchive,

    # Output path for the CSV report.
    [string]$ExportPath = ".\MailboxStorageReport_$(Get-Date -Format 'yyyyMMdd').csv",

    # Auth mode passed through to Assert-M365Connection (Interactive/AppSecret/Certificate).
    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services ExchangeOnline -AuthMode $AuthMode
#endregion

Write-Host "Pulling mailbox size/quota for all user mailboxes (this can take a while on large tenants)..." -ForegroundColor Cyan
try {
    $mailboxes = Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox
}
catch {
    Write-Error "Failed to retrieve mailbox list: $($_.Exception.Message)"
    return
}

$report = foreach ($mbx in $mailboxes) {
    try {
        $stats = Get-MailboxStatistics -Identity $mbx.PrimarySmtpAddress
    }
    catch {
        Write-Warning "Failed to retrieve statistics for $($mbx.PrimarySmtpAddress): $($_.Exception.Message)"
        continue
    }

    $quotaGB = if ($mbx.ProhibitSendReceiveQuota -match '(\d+\.?\d*)\s*GB') { [double]$matches[1] } else { $null }
    $usedGB = if ($stats.TotalItemSize) { [math]::Round(($stats.TotalItemSize.ToString() -replace '.*\(([\d,]+) bytes\).*','$1' -replace ',','') / 1GB, 2) } else { 0 }
    $percentUsed = if ($quotaGB) { [math]::Round(($usedGB / $quotaGB) * 100, 1) } else { $null }

    $archiveInfo = $null
    if ($IncludeArchive -and $mbx.ArchiveStatus -eq "Active") {
        try {
            $archiveStats = Get-MailboxStatistics -Identity $mbx.PrimarySmtpAddress -Archive -ErrorAction Stop
            $archiveInfo = $archiveStats.TotalItemSize.ToString()
        }
        catch {
            Write-Warning "Failed to retrieve archive statistics for $($mbx.PrimarySmtpAddress): $($_.Exception.Message)"
        }
    }

    [PSCustomObject]@{
        DisplayName    = $mbx.DisplayName
        UPN            = $mbx.PrimarySmtpAddress
        UsedGB         = $usedGB
        QuotaGB        = $quotaGB
        PercentUsed    = $percentUsed
        ArchiveEnabled = $mbx.ArchiveStatus -eq "Active"
        ArchiveSize    = $archiveInfo
        Flag           = if ($percentUsed -ge $WarningPercentThreshold) { "WARNING" } else { "OK" }
    }
}

$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Exported $($report.Count) mailbox(es) to $ExportPath" -ForegroundColor Green

$warn = $report | Where-Object { $_.Flag -eq "WARNING" }
if ($warn) {
    Write-Host "`n=== $($warn.Count) mailbox(es) over $WarningPercentThreshold% quota ===" -ForegroundColor Red
    $warn | Sort-Object PercentUsed -Descending | Format-Table DisplayName, UPN, UsedGB, QuotaGB, PercentUsed -AutoSize
    Write-Host "Fixes: enable/expand archive, raise quota if licensing allows, or have the user clean up large attachments."
}
else {
    Write-Host "`nNo mailboxes over $WarningPercentThreshold% - all clear." -ForegroundColor Green
}
