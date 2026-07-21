<#
.SYNOPSIS
    Bulk-exports compliance/audit log data for multiple tenants.

.DESCRIPTION
    CSV-driven bulk orchestrator. Reads a CSV of tenant rows (column: TenantName,
    required) and, for each row, calls the per-tenant operational script
    ..\security\Export-ComplianceAuditData.ps1 to export compliance audit data for
    the given date range and record type. Each row is processed independently and
    wrapped in try/catch so that a single tenant failure (bad tenant name, auth
    failure, network blip) does not abort the entire run. Per-tenant export CSVs
    are written as before; in addition, a single summary CSV recording
    Success/Failed status per tenant is written at the end for audit and retry
    handling.

.PARAMETER CsvPath
    Path to the input CSV file. Must contain a TenantName column.

.PARAMETER StartDate
    Start of the audit log date range to export, applied to every tenant.

.PARAMETER EndDate
    End of the audit log date range to export, applied to every tenant.

.PARAMETER RecordType
    Unified audit log record type to export (e.g. ExchangeAdmin). Defaults to
    ExchangeAdmin; applied to every tenant in the run.

.EXAMPLE
    .\Invoke-BulkComplianceAuditExport.ps1 -CsvPath .\tenants.csv -StartDate '2026-06-01' -EndDate '2026-06-30'

    Exports June compliance audit data for every tenant listed in tenants.csv and
    writes a BulkComplianceAuditExportSummary CSV.
#>
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [Parameter(Mandatory)][datetime]$StartDate,
    [Parameter(Mandatory)][datetime]$EndDate,
    # Unified audit log record type applied to every tenant in the run
    [string]$RecordType = 'ExchangeAdmin'
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$script:ReportsFolderRelativePath = '..\reports'
$script:TimestampFormat = 'yyyyMMddHHmmss'

$rows = Import-Csv -Path $CsvPath
$results = foreach ($row in $rows) {
    $out = Join-Path $PSScriptRoot "$($script:ReportsFolderRelativePath)\ComplianceAudit_$($row.TenantName)_$(Get-Date -Format $script:TimestampFormat).csv"
    try {
        & (Join-Path $PSScriptRoot '..\security\Export-ComplianceAuditData.ps1') -TenantName $row.TenantName -StartDate $StartDate -EndDate $EndDate -OutputCsv $out -RecordType $RecordType
        [pscustomobject]@{ TenantName=$row.TenantName; ReportPath=$out; Status='Success'; Error='' }
    }
    catch {
        [pscustomobject]@{ TenantName=$row.TenantName; ReportPath=$out; Status='Failed'; Error=$_.Exception.Message }
    }
}
$out = Join-Path (Join-Path $PSScriptRoot $script:ReportsFolderRelativePath) ("BulkComplianceAuditExportSummary_{0}.csv" -f (Get-Date -Format $script:TimestampFormat))
$results | Export-Csv -NoTypeInformation -Path $out
$out
