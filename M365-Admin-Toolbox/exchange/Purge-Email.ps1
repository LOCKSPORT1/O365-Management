<#
.SYNOPSIS
    Searches one or more mailboxes for messages matching a mandatory filter and, optionally, purges them via
    a Microsoft Purview compliance search.

.DESCRIPTION
    Runs a bounded, filtered Content Search (New-ComplianceSearch) against a specific target mailbox (or an
    explicit list of mailboxes) and reports the number of matching items per mailbox WITHOUT deleting anything.
    Deletion only happens if the caller both passes -Mode Purge AND the explicit -Confirmed switch; otherwise
    the script always stops after the preview/estimate phase. This script uses SupportsShouldProcess, so the
    actual purge action is also gated behind ShouldProcess (-WhatIf / -Confirm are fully honored, in addition
    to the -Confirmed gate).

    Safety rules enforced by this script:
      - At least one narrowing search term (Subject, SenderAddress, MessageId, and/or a date range) is
        required to build $SearchQuery. A bare wildcard/empty query is rejected so an org-wide unbounded
        purge cannot happen by accident.
      - The search/estimate phase always runs first and logs the item count and affected mailbox(es) before
        any destructive action is possible.
      - PurgeType defaults to SoftDelete (recoverable), never HardDelete, unless explicitly overridden.
      - The destructive purge action requires -Mode Purge, -Confirmed, and ShouldProcess confirmation all
        at once. Running with -Mode Search (the default) never deletes anything.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. Tenant-Example-NA).

.PARAMETER TargetMailbox
    Primary SMTP address of the single mailbox to search/purge. Use -TargetMailboxes for multiple mailboxes.
    At least one of -TargetMailbox / -TargetMailboxes must be supplied; unbounded/org-wide (all mailboxes)
    searches are not supported by this script.

.PARAMETER TargetMailboxes
    Array of primary SMTP addresses to search/purge, for when more than one mailbox is in scope.

.PARAMETER SenderAddress
    Restrict the search to messages from this sender. Optional, but at least one of SenderAddress, Subject,
    MessageId, or StartDate/EndDate must be supplied to form a valid, bounded search query.

.PARAMETER Subject
    Restrict the search to messages with this subject (substring match).

.PARAMETER MessageId
    Restrict the search to a specific Internet Message-Id header value. This is the most precise filter.

.PARAMETER StartDate
    Restrict the search to messages received on/after this date. Combine with -EndDate for a bounded window.

.PARAMETER EndDate
    Restrict the search to messages received on/before this date.

.PARAMETER SearchQuery
    Optional raw KQL query fragment to AND together with the filters above for advanced scenarios. This
    cannot be used by itself to bypass the mandatory-filter requirement -- at least one of SenderAddress,
    Subject, MessageId, or StartDate/EndDate is still required.

.PARAMETER Mode
    'Search' (default) runs the preview/estimate phase only and never deletes anything. 'Purge' additionally
    attempts the destructive purge action, but only if -Confirmed is also supplied and ShouldProcess is
    confirmed.

.PARAMETER Confirmed
    Explicit safety gate. Must be supplied (in addition to -Mode Purge) for the purge action to execute.
    This is separate from PowerShell's built-in -Confirm/ShouldProcess prompt, which also applies.

.PARAMETER PurgeType
    'SoftDelete' (default, recoverable from Recoverable Items/Deleted Items for the mailbox retention window)
    or 'HardDelete' (unrecoverable). HardDelete must be explicitly requested.

.EXAMPLE
    .\Purge-Email.ps1 -TenantName Tenant-Example-NA -TargetMailbox user@contoso.com -SenderAddress phish@evil-example.com -Subject "Invoice overdue"

    Preview-only: runs the compliance search and reports matching item counts. Nothing is deleted.

.EXAMPLE
    .\Purge-Email.ps1 -TenantName Tenant-Example-NA -TargetMailbox user@contoso.com -MessageId "<abc123@evil-example.com>" -Mode Purge -Confirmed -PurgeType SoftDelete

    Runs the search, shows the preview, and (after ShouldProcess confirmation) soft-deletes the matching
    messages from the target mailbox.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$TargetMailbox,
    [string[]]$TargetMailboxes,
    [string]$SenderAddress,
    [string]$Subject,
    [string]$MessageId,
    [datetime]$StartDate,
    [datetime]$EndDate,
    [string]$SearchQuery,
    [ValidateSet('Search','Purge')][string]$Mode = 'Search',
    [switch]$Confirmed,
    [ValidateSet('SoftDelete','HardDelete')][string]$PurgeType = 'SoftDelete'
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# How many seconds to wait between compliance search status polls
$SearchPollSeconds = 10
# Maximum number of status polls before giving up on the search completing
$MaxSearchPollAttempts = 90

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectExchange -ConnectPurview

# --- Resolve target mailbox scope. An explicit, non-empty target is mandatory: this script will never
#     run an unbounded/org-wide search. ---
$allTargets = @()
if ($TargetMailbox) { $allTargets += $TargetMailbox }
if ($TargetMailboxes) { $allTargets += $TargetMailboxes }
$allTargets = $allTargets | Where-Object { $_ } | Select-Object -Unique

if (-not $allTargets -or $allTargets.Count -eq 0) {
    throw "You must specify -TargetMailbox or -TargetMailboxes. Org-wide/unbounded searches are not supported by this script."
}

# --- Build a mandatory, narrowing content match query. At least one real filter is required so a bare
#     wildcard search across an entire mailbox cannot be constructed. ---
$queryParts = @()
if ($SenderAddress) { $queryParts += "From:`"$SenderAddress`"" }
if ($Subject) { $queryParts += "Subject:`"$Subject`"" }
if ($MessageId) { $queryParts += "MessageId:`"$MessageId`"" }
if ($StartDate) { $queryParts += "Received>=$($StartDate.ToString('MM/dd/yyyy'))" }
if ($EndDate) { $queryParts += "Received<=$($EndDate.ToString('MM/dd/yyyy'))" }

if ($queryParts.Count -eq 0 -and -not $SearchQuery) {
    throw "At least one narrowing filter is required: -SenderAddress, -Subject, -MessageId, or -StartDate/-EndDate. A bare/unbounded query is not permitted."
}

$builtQuery = $queryParts -join ' AND '
if ($SearchQuery) {
    $finalQuery = if ($builtQuery) { "($builtQuery) AND ($SearchQuery)" } else { $SearchQuery }
} else {
    $finalQuery = $builtQuery
}

if ([string]::IsNullOrWhiteSpace($finalQuery)) {
    throw "Resulting search query is empty. Refusing to run an unbounded search."
}

$searchName = "Purge_$(($allTargets -join '_').Replace('@','_'))_$(Get-Date -Format 'yyyyMMddHHmmss')"

Invoke-ToolboxSafely -TenantName $TenantName -Operation "ComplianceSearch:$searchName" -Rethrow -ScriptBlock {

    Write-ToolboxLog -TenantName $TenantName -Message "Creating compliance search $searchName for targets: $($allTargets -join ', ') with query: $finalQuery"
    Invoke-WithRetry -TenantName $TenantName -Operation 'New-ComplianceSearch' -ScriptBlock {
        New-ComplianceSearch -Name $searchName -ExchangeLocation $allTargets -ContentMatchQuery $finalQuery | Out-Null
    }
    Start-ComplianceSearch -Identity $searchName | Out-Null

    $pollCount = 0
    do {
        Start-Sleep -Seconds $SearchPollSeconds
        $status = Get-ComplianceSearch -Identity $searchName
        $pollCount++
        Write-ToolboxLog -TenantName $TenantName -Message "Search status: $($status.Status) (poll $pollCount/$MaxSearchPollAttempts)"
        if ($pollCount -ge $MaxSearchPollAttempts) {
            throw "Compliance search '$searchName' did not complete after $MaxSearchPollAttempts polls. Aborting before any purge action."
        }
    } until ($status.Status -eq 'Completed')

    # --- Preview phase: always show item counts / affected mailboxes before any deletion is possible. ---
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Search completed. Items found: $($status.Items). Size: $($status.Size). Query: $finalQuery"
    if ($status.SuccessResults) {
        Write-ToolboxLog -TenantName $TenantName -Message "Per-location results: $($status.SuccessResults)"
    }

    if ($status.Items -eq 0) {
        Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "No items matched the search query. Nothing to purge."
        return
    }

    if ($Mode -ne 'Purge') {
        Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "Mode is '$Mode'. This was a search/preview only -- no purge action was taken. Re-run with -Mode Purge -Confirmed to delete these items."
        return
    }

    if (-not $Confirmed) {
        Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "-Mode Purge was specified but -Confirmed was not. Refusing to execute the destructive purge action. Re-run with -Confirmed to proceed."
        return
    }

    $purgeTarget = "$($allTargets -join ', ') ($($status.Items) items matching: $finalQuery)"
    if ($PSCmdlet.ShouldProcess($purgeTarget, "Purge ($PurgeType) via compliance search '$searchName'")) {
        Invoke-WithRetry -TenantName $TenantName -Operation 'New-ComplianceSearchAction-Purge' -ScriptBlock {
            New-ComplianceSearchAction -SearchName $searchName -Purge -PurgeType $PurgeType -Confirm:$false | Out-Null
        }
        Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Purge action ($PurgeType) started for $searchName affecting $($status.Items) items."
    } else {
        Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "Purge action for $searchName was not confirmed (ShouldProcess declined). No items were deleted."
    }
}
