<#
.SYNOPSIS
    Runs a message trace (who sent/received what, when, and delivery
    status) and exports it to CSV. Handles both the ~10 day recent window
    and the historical search API for anything older.

.DESCRIPTION
    Get-MessageTrace only covers the last 10 days. For anything older
    (up to 90 days on most tenant plans), this script automatically falls
    back to Start-HistoricalSearch / Get-HistoricalSearch, which is async
    (Microsoft emails/queues the result) - the script polls for completion
    when using that path.

.NOTES
    Self-connects to Exchange Online automatically if not already connected
    (see -AuthMode param; defaults to Interactive). No manual dot-sourcing
    required - Connect-M365Services.ps1 is called internally.
#>

[CmdletBinding()]
param(
    [datetime]$StartDate,
    [datetime]$EndDate = (Get-Date),
    [string]$SenderAddress,
    [string]$RecipientAddress,
    [string]$Subject,
    [string]$Status,                     # e.g. Delivered, Failed, FilteredAsSpam, Quarantined
    [string]$ExportPath,
    [int]$HistoricalPollIntervalSeconds,
    [int]$HistoricalMaxWaitMinutes,
    [int]$HistoricalSearchThresholdDays,

    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Default lookback window when -StartDate is not specified.
if (-not $PSBoundParameters.ContainsKey('StartDate')) { $StartDate = (Get-Date).AddDays(-2) }

# Default CSV export path/name for recent-window (non-historical) traces.
if (-not $ExportPath) { $ExportPath = ".\MessageTrace_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv" }

# How often (seconds) to poll Get-HistoricalSearch for completion.
if (-not $HistoricalPollIntervalSeconds) { $HistoricalPollIntervalSeconds = 60 }

# Ceiling (minutes) to wait on a historical search before giving up polling.
if (-not $HistoricalMaxWaitMinutes) { $HistoricalMaxWaitMinutes = 20 }

# Get-MessageTrace only reliably covers this many days; older ranges use the
# async historical search API instead.
if (-not $HistoricalSearchThresholdDays) { $HistoricalSearchThresholdDays = 10 }

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services ExchangeOnline -AuthMode $AuthMode
#endregion

$isHistorical = (Get-Date) - $StartDate -gt (New-TimeSpan -Days $HistoricalSearchThresholdDays)

if (-not $isHistorical) {
    Write-Host "Running standard message trace ($StartDate to $EndDate)..." -ForegroundColor Cyan

    $params = @{
        StartDate = $StartDate
        EndDate   = $EndDate
    }
    if ($SenderAddress)    { $params.SenderAddress = $SenderAddress }
    if ($RecipientAddress) { $params.RecipientAddress = $RecipientAddress }
    if ($Status)           { $params.Status = $Status }

    try {
        $results = Get-MessageTrace @params -PageSize 5000
    }
    catch {
        Write-Error "Get-MessageTrace failed: $_"
        return
    }
    if ($Subject) { $results = $results | Where-Object { $_.Subject -like "*$Subject*" } }

    try {
        $results | Export-Csv -Path $ExportPath -NoTypeInformation
        Write-Host "Exported $($results.Count) message(s) to $ExportPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to export results to '$ExportPath': $_"
    }
}
else {
    Write-Host "Date range exceeds $HistoricalSearchThresholdDays days - submitting a historical search (async, can take a while)..." -ForegroundColor Cyan

    $searchName = "MsgTrace_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $params = @{
        ReportTitle  = $searchName
        StartDate    = $StartDate
        EndDate      = $EndDate
        ReportType   = "MessageTrace"
    }
    if ($SenderAddress)    { $params.SenderAddress = $SenderAddress }
    if ($RecipientAddress) { $params.RecipientAddress = $RecipientAddress }

    try {
        Start-HistoricalSearch @params
    }
    catch {
        Write-Error "Start-HistoricalSearch failed: $_"
        return
    }

    $deadline = (Get-Date).AddMinutes($HistoricalMaxWaitMinutes)
    do {
        Start-Sleep -Seconds $HistoricalPollIntervalSeconds
        $search = Get-HistoricalSearch | Where-Object { $_.ReportTitle -eq $searchName }
        Write-Host "  Status: $($search.Status)"
    } while ($search.Status -notin @("Done","Failed") -and (Get-Date) -lt $deadline)

    if ($search.Status -eq "Done") {
        Write-Host "[OK] Historical search complete. Download link:" -ForegroundColor Green
        Write-Host "  $($search.FileUrl)"
        Write-Host "Note: historical search results are delivered as a downloadable file via the returned URL, not directly to this CSV path - script cannot auto-download this one on your behalf."
    }
    else {
        Write-Warning "Historical search did not complete within $HistoricalMaxWaitMinutes minutes (status: $($search.Status)). Check Get-HistoricalSearch later for status/download link."
    }
}
