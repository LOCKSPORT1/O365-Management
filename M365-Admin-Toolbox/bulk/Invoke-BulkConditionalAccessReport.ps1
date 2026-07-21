<#
.SYNOPSIS
    Bulk-generates Conditional Access policy reports for multiple tenants.

.DESCRIPTION
    CSV-driven bulk orchestrator. Reads a CSV of tenant rows (column: TenantName,
    required) and, for each row, calls the per-tenant operational script
    ..\entra\Report-ConditionalAccessPolicies.ps1 to produce a Conditional Access
    policy report. Each row is processed independently and wrapped in try/catch
    so that a single tenant failure (bad tenant name, auth failure, network blip)
    does not abort the entire run. Per-tenant report CSVs are written as before;
    in addition, a single summary CSV recording Success/Failed status per tenant
    is written at the end for audit and retry handling.

.PARAMETER CsvPath
    Path to the input CSV file. Must contain a TenantName column.

.EXAMPLE
    .\Invoke-BulkConditionalAccessReport.ps1 -CsvPath .\tenants.csv

    Processes every tenant listed in tenants.csv and writes per-tenant
    Conditional Access policy reports plus a BulkConditionalAccessReportSummary CSV.
#>
param([Parameter(Mandatory)][string]$CsvPath)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$script:ReportsFolderRelativePath = '..\reports'
$script:TimestampFormat = 'yyyyMMddHHmmss'

$rows = Import-Csv -Path $CsvPath
$results = foreach ($row in $rows) {
    $out = Join-Path $PSScriptRoot "$($script:ReportsFolderRelativePath)\ConditionalAccessPolicies_$($row.TenantName)_$(Get-Date -Format $script:TimestampFormat).csv"
    try {
        & (Join-Path $PSScriptRoot '..\entra\Report-ConditionalAccessPolicies.ps1') -TenantName $row.TenantName -OutputCsv $out
        [pscustomobject]@{ TenantName=$row.TenantName; ReportPath=$out; Status='Success'; Error='' }
    }
    catch {
        [pscustomobject]@{ TenantName=$row.TenantName; ReportPath=$out; Status='Failed'; Error=$_.Exception.Message }
    }
}
$out = Join-Path (Join-Path $PSScriptRoot $script:ReportsFolderRelativePath) ("BulkConditionalAccessReportSummary_{0}.csv" -f (Get-Date -Format $script:TimestampFormat))
$results | Export-Csv -NoTypeInformation -Path $out
$out
