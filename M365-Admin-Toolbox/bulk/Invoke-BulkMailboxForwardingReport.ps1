<#
.SYNOPSIS
    Bulk-generates mailbox forwarding reports for multiple tenants.

.DESCRIPTION
    CSV-driven bulk orchestrator. Reads a CSV of tenant rows (column: TenantName,
    required) and, for each row, calls the per-tenant operational script
    ..\exchange\Report-MailboxForwarding.ps1 to produce a mailbox forwarding
    report. Each row is processed independently and wrapped in try/catch so that
    a single tenant failure (bad tenant name, auth failure, network blip) does
    not abort the entire run. Per-tenant report CSVs are written as before; in
    addition, a single summary CSV recording Success/Failed status per tenant is
    written at the end for audit and retry handling.

.PARAMETER CsvPath
    Path to the input CSV file. Must contain a TenantName column.

.PARAMETER IncludeInboxRules
    Applied to every tenant. Passed through to Report-MailboxForwarding.ps1 to
    include inbox forwarding rules in the report.

.EXAMPLE
    .\Invoke-BulkMailboxForwardingReport.ps1 -CsvPath .\tenants.csv -IncludeInboxRules

    Processes every tenant listed in tenants.csv and writes per-tenant mailbox
    forwarding reports (including inbox rules) plus a BulkMailboxForwardingReportSummary CSV.
#>
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [switch]$IncludeInboxRules
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$script:ReportsFolderRelativePath = '..\reports'
$script:TimestampFormat = 'yyyyMMddHHmmss'

$rows = Import-Csv -Path $CsvPath
$results = foreach ($row in $rows) {
    $out = Join-Path $PSScriptRoot "$($script:ReportsFolderRelativePath)\MailboxForwarding_$($row.TenantName)_$(Get-Date -Format $script:TimestampFormat).csv"
    try {
        & (Join-Path $PSScriptRoot '..\exchange\Report-MailboxForwarding.ps1') -TenantName $row.TenantName -OutputCsv $out -IncludeInboxRules:$IncludeInboxRules
        [pscustomobject]@{ TenantName=$row.TenantName; ReportPath=$out; Status='Success'; Error='' }
    }
    catch {
        [pscustomobject]@{ TenantName=$row.TenantName; ReportPath=$out; Status='Failed'; Error=$_.Exception.Message }
    }
}
$out = Join-Path (Join-Path $PSScriptRoot $script:ReportsFolderRelativePath) ("BulkMailboxForwardingReportSummary_{0}.csv" -f (Get-Date -Format $script:TimestampFormat))
$results | Export-Csv -NoTypeInformation -Path $out
$out
