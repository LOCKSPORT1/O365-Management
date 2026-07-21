<#
.SYNOPSIS
    CSV-driven bulk orchestrator for stale Intune device reporting across multiple tenants.
.DESCRIPTION
    Reads a CSV of tenant rows (must include a TenantName column) and, for each row,
    invokes ..\intune\Report-StaleDevices.ps1 with -TenantName, -InactiveDays, and
    -OutputCsv to produce a per-tenant stale device report. Each row is wrapped in
    try/catch so a single tenant failure (bad tenant name, auth failure, network blip)
    does not abort the run for the remaining tenants. After processing all rows, a
    summary CSV recording per-tenant Status/Error is written to the reports folder for
    audit and retry handling, and its path is written to the pipeline as the last output.
.PARAMETER CsvPath
    Path to the input CSV file. Must contain at minimum a TenantName column.
.PARAMETER InactiveDays
    Inactivity threshold, in days, used to flag a device as stale.
.EXAMPLE
    .\Invoke-BulkStaleDeviceReport.ps1 -CsvPath 'C:\data\tenants.csv' -InactiveDays 45

    Runs the stale device report (devices inactive 45+ days) for every tenant listed in
    tenants.csv and writes both per-tenant report CSVs and a summary CSV to the reports
    folder.
#>
param(
    [Parameter(Mandatory)][string]$CsvPath,
    # Inactivity threshold, in days, used to flag a device as stale
    [int]$InactiveDays = 30
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$script:ReportsFolderRelativePath = '..\reports'
$script:TimestampFormat = 'yyyyMMddHHmmss'

$rows = Import-Csv -Path $CsvPath
$results = foreach ($row in $rows) {
    try {
        $out = Join-Path $PSScriptRoot ("{0}\StaleDevices_{1}_{2}.csv" -f $script:ReportsFolderRelativePath, $row.TenantName, (Get-Date -Format $script:TimestampFormat))
        & (Join-Path $PSScriptRoot '..\intune\Report-StaleDevices.ps1') -TenantName $row.TenantName -InactiveDays $InactiveDays -OutputCsv $out
        [pscustomobject]@{ TenantName=$row.TenantName; ReportPath=$out; Status='Success'; Error='' }
    }
    catch {
        [pscustomobject]@{ TenantName=$row.TenantName; ReportPath=''; Status='Failed'; Error=$_.Exception.Message }
    }
}
$summaryOut = Join-Path (Join-Path $PSScriptRoot $script:ReportsFolderRelativePath) ("BulkStaleDeviceReportSummary_{0}.csv" -f (Get-Date -Format $script:TimestampFormat))
$results | Export-Csv -NoTypeInformation -Path $summaryOut
$summaryOut
