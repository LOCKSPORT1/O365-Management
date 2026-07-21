<#
.SYNOPSIS
    Bulk-generates mailbox audit reports for multiple tenants.

.DESCRIPTION
    CSV-driven bulk orchestrator. Reads a CSV of tenant rows (columns: TenantName,
    required; MailboxFilter, optional per-row mailbox filter string, defaults to
    '*' when omitted) and, for each row, calls the per-tenant operational script
    ..\exchange\Audit-Mailboxes.ps1 to produce a mailbox audit report. Each row is
    processed independently and wrapped in try/catch so that a single tenant
    failure (bad tenant name, auth failure, network blip) does not abort the
    entire run. Per-tenant report CSVs are written as before; in addition, a
    single summary CSV recording Success/Failed status per tenant is written at
    the end for audit and retry handling.

.PARAMETER CsvPath
    Path to the input CSV file. Must contain a TenantName column; may optionally
    contain a MailboxFilter column per row.

.PARAMETER SharedOnly
    Applied to every tenant. Passed through to Audit-Mailboxes.ps1 to restrict
    the audit to shared mailboxes only.

.EXAMPLE
    .\Invoke-BulkMailboxAudit.ps1 -CsvPath .\tenants.csv -SharedOnly

    Processes every tenant listed in tenants.csv and writes per-tenant shared
    mailbox audit reports plus a BulkMailboxAuditSummary CSV.
#>
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [switch]$SharedOnly
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$script:ReportsFolderRelativePath = '..\reports'
$script:TimestampFormat = 'yyyyMMddHHmmss'
$script:DefaultMailboxFilter = '*'

$rows = Import-Csv -Path $CsvPath
$results = foreach ($row in $rows) {
    $name = $row.TenantName
    $filter = if ($row.MailboxFilter) { $row.MailboxFilter } else { $script:DefaultMailboxFilter }
    $out = Join-Path $PSScriptRoot "$($script:ReportsFolderRelativePath)\MailboxAudit_$($name)_$(Get-Date -Format $script:TimestampFormat).csv"
    try {
        & (Join-Path $PSScriptRoot '..\exchange\Audit-Mailboxes.ps1') -TenantName $name -MailboxFilter $filter -SharedOnly:$SharedOnly -OutputCsv $out
        [pscustomobject]@{ TenantName=$name; ReportPath=$out; Status='Success'; Error='' }
    }
    catch {
        [pscustomobject]@{ TenantName=$name; ReportPath=$out; Status='Failed'; Error=$_.Exception.Message }
    }
}
$out = Join-Path (Join-Path $PSScriptRoot $script:ReportsFolderRelativePath) ("BulkMailboxAuditSummary_{0}.csv" -f (Get-Date -Format $script:TimestampFormat))
$results | Export-Csv -NoTypeInformation -Path $out
$out
