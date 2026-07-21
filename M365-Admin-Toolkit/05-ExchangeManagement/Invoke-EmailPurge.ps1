<#
.SYNOPSIS
    Searches mailboxes org-wide for a malicious/unwanted message (by
    sender, subject, or a specific message ID) and optionally purges it
    across every mailbox it landed in - the standard "phishing email got
    through, get it out of every inbox" response.

.DESCRIPTION
    Wraps Security & Compliance Center compliance search + purge actions
    (New-ComplianceSearch / New-ComplianceSearchAction). This is the
    supported, auditable path for bulk mailbox purges - it replaces the
    old Search-Mailbox -DeleteContent cmdlet, which is deprecated/retired.

    Two-phase by design:
      1. -Mode Preview  : runs the search only, shows you item count and
                            which mailboxes matched, so you can sanity check
                            before deleting anything.
      2. -Mode Purge     : runs (or reuses) the search, then submits a purge
                            action. Requires -Confirmed.

    Purge types:
      - SoftDelete : moves matches to Recoverable Items (recoverable for
                      the mailbox's deleted item retention window). Default
                      and recommended.
      - HardDelete : permanently removed, no recovery. Use only when you're
                      certain.

.PARAMETER Confirmed
    Required in addition to -Mode Purge before any purge action is submitted.
    This is on top of standard SupportsShouldProcess (-WhatIf/-Confirm) - both
    gates must be satisfied to actually delete anything.

.PARAMETER LogPath
    Text log of every search/purge action taken by this script (append mode).
    Defaults to .\EmailPurge_Log.txt.

.EXAMPLE
    # Step 1: search/estimate only, deletes nothing
    .\Invoke-EmailPurge.ps1 -Mode Preview -SenderAddress "phish@bad-domain.com" -Subject "Invoice overdue"

.EXAMPLE
    # Step 2: reuse that search and purge, with explicit confirmation gate
    .\Invoke-EmailPurge.ps1 -Mode Purge -SearchName "Purge_20260630_143000" -Confirmed

.NOTES
    Requires the ComplianceCenter session:
        Connect-M365 -Services ComplianceCenter
    The account/app needs the "eDiscovery Manager" (or "eDiscovery
    Administrator") role in the Security & Compliance Center - Global Admin
    alone is NOT sufficient for compliance search actions on most tenants.

    Safety gates before any purge fires: (1) a search/estimate must complete
    first (Preview or a prior named search), (2) -Confirmed switch, (3) the
    standard SupportsShouldProcess -WhatIf/-Confirm gate. All searches and
    purge actions are appended to -LogPath.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory)][ValidateSet("Preview","Purge")]
    [string]$Mode,

    [string]$SearchName = "Purge_$(Get-Date -Format 'yyyyMMdd_HHmmss')",
    [string]$SenderAddress,
    [string]$Subject,
    [string]$MessageId,                    # Internet Message ID if you have it - most precise
    [datetime]$ReceivedAfter,
    [datetime]$ReceivedBefore,

    [ValidateSet("SoftDelete","HardDelete")]
    [string]$PurgeType,

    [switch]$Confirmed,                     # required to actually run a Purge - safety gate
    [int]$PollIntervalSeconds,
    [int]$MaxWaitMinutes,
    [string]$LogPath,

    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Default purge type if -PurgeType is not specified. SoftDelete (recoverable
# via Recoverable Items) is strongly recommended; HardDelete is permanent.
if (-not $PurgeType) { $PurgeType = "SoftDelete" }

# How often (seconds) to poll compliance search / purge action status.
if (-not $PollIntervalSeconds) { $PollIntervalSeconds = 20 }

# Ceiling (minutes) to wait on a search/purge action before giving up polling
# (the server-side job keeps running even if this script stops waiting).
if (-not $MaxWaitMinutes) { $MaxWaitMinutes = 10 }

# Where to append a text log of every search/purge action this script takes.
if (-not $LogPath) { $LogPath = ".\EmailPurge_Log.txt" }

function Write-PurgeLog {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message"
    Add-Content -Path $LogPath -Value $line
}

if (-not $SenderAddress -and -not $Subject -and -not $MessageId) {
    Write-Error "Provide at least one of -SenderAddress, -Subject, or -MessageId to build a search query. Aborting - refusing to run an unbounded org-wide search."
    return
}

if ($Mode -eq "Purge" -and -not $Confirmed) {
    Write-Error "Purge requires -Confirmed. Run with -Mode Preview first to verify scope, then re-run with -Mode Purge -Confirmed."
    return
}

#region Connect - ensures the required Compliance Center session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services ComplianceCenter -AuthMode $AuthMode
#endregion


# Build the KQL query for the compliance search
$queryParts = @()
if ($SenderAddress) { $queryParts += "From:$SenderAddress" }
if ($Subject)       { $queryParts += "Subject:`"$Subject`"" }
if ($MessageId)      { $queryParts += "MessageId:$MessageId" }
if ($ReceivedAfter)  { $queryParts += "Received>=$($ReceivedAfter.ToString('MM/dd/yyyy'))" }
if ($ReceivedBefore) { $queryParts += "Received<=$($ReceivedBefore.ToString('MM/dd/yyyy'))" }
$query = $queryParts -join " AND "

Write-Host "Query: $query" -ForegroundColor Cyan
Write-PurgeLog "Mode=$Mode SearchName=$SearchName Query='$query' PurgeType=$PurgeType"

# Check for an existing search with this name (lets you re-run Purge against a Preview you already ran)
$existing = Get-ComplianceSearch -Identity $SearchName -ErrorAction SilentlyContinue

if (-not $existing) {
    Write-Host "Creating compliance search '$SearchName' scoped to all mailboxes..." -ForegroundColor Cyan
    try {
        New-ComplianceSearch -Name $SearchName -ExchangeLocation All -ContentMatchQuery $query | Out-Null
        Start-ComplianceSearch -Identity $SearchName
    }
    catch {
        Write-Error "Failed to create/start compliance search '$SearchName': $_"
        Write-PurgeLog "ERROR creating/starting search '$SearchName': $_"
        return
    }

    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    do {
        Start-Sleep -Seconds $PollIntervalSeconds
        $search = Get-ComplianceSearch -Identity $SearchName
        Write-Host "  Status: $($search.Status) | Items so far: $($search.Items)"
    } while ($search.Status -ne "Completed" -and (Get-Date) -lt $deadline)
}
else {
    $search = $existing
    Write-Host "Reusing existing search '$SearchName' (Status: $($search.Status), Items: $($search.Items))." -ForegroundColor Yellow
}

if ($search.Status -ne "Completed") {
    Write-Warning "Search did not reach Completed status within $MaxWaitMinutes minutes (currently: $($search.Status)). Check Get-ComplianceSearch -Identity $SearchName later, then re-run this script (it will reuse the search by name)."
    Write-PurgeLog "Search '$SearchName' did not complete within $MaxWaitMinutes min (status: $($search.Status))."
    return
}

Write-Host "`n=== Search complete: $($search.Items) item(s) matched across the tenant ===" -ForegroundColor Cyan
Get-ComplianceSearch -Identity $SearchName | Select-Object -ExpandProperty SearchResults | Out-String | Write-Host
Write-PurgeLog "Search '$SearchName' completed. Items matched: $($search.Items)"

if ($Mode -eq "Preview") {
    Write-Host "`nPreview complete. No content was removed. Review the item count/mailboxes above." -ForegroundColor Green
    Write-Host "To purge, re-run with: -Mode Purge -SearchName '$SearchName' -Confirmed"
    return
}

# Mode -eq Purge from here. -Confirmed was already validated above; -WhatIf/-Confirm
# (SupportsShouldProcess) gives a second, standard PowerShell-native safety gate.
$purgeTarget = "$($search.Items) item(s) matching query '$query' (search '$SearchName')"
if (-not $PSCmdlet.ShouldProcess($purgeTarget, "$PurgeType purge")) {
    Write-Host "Purge skipped (WhatIf or declined)." -ForegroundColor Yellow
    Write-PurgeLog "Purge skipped via ShouldProcess/-WhatIf for search '$SearchName'."
    return
}

if ($PurgeType -eq "HardDelete") {
    Write-Warning "HardDelete is PERMANENT and unrecoverable. Proceeding because -Confirmed and ShouldProcess were both satisfied."
}

Write-Host "`nSubmitting $PurgeType purge action for $($search.Items) item(s)..." -ForegroundColor Yellow
Write-PurgeLog "Submitting $PurgeType purge action for search '$SearchName' ($($search.Items) items)."

try {
    New-ComplianceSearchAction -SearchName $SearchName -Purge -PurgeType $PurgeType -Confirm:$false | Out-Null
}
catch {
    Write-Error "Failed to submit purge action for '$SearchName': $_"
    Write-PurgeLog "ERROR submitting purge action for '$SearchName': $_"
    return
}

$actionName = "$SearchName" + "_Purge"
$deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
do {
    Start-Sleep -Seconds $PollIntervalSeconds
    $action = Get-ComplianceSearchAction -Identity $actionName -ErrorAction SilentlyContinue
    Write-Host "  Purge action status: $($action.Status)"
} while ($action.Status -notin @("Completed","Failed") -and (Get-Date) -lt $deadline)

if ($action.Status -eq "Completed") {
    Write-Host "`n[OK] Purge completed. $PurgeType applied to matched items." -ForegroundColor Green
    Write-PurgeLog "Purge action '$actionName' completed. PurgeType=$PurgeType Items=$($search.Items)"
    if ($PurgeType -eq "SoftDelete") {
        Write-Host "Items moved to Recoverable Items - recoverable within each mailbox's deleted item retention window if this needs to be reversed."
    }
}
else {
    Write-Warning "Purge action status: $($action.Status). Check Get-ComplianceSearchAction -Identity '$actionName' -Details for the per-mailbox breakdown."
    Write-PurgeLog "Purge action '$actionName' ended with status: $($action.Status)"
}
