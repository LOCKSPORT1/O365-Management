<#
.SYNOPSIS
    Bulk-generates license inventory reports for multiple tenants.

.DESCRIPTION
    CSV-driven bulk orchestrator. Reads a CSV of tenant rows (column: TenantName,
    required) and, for each row, calls the per-tenant operational script
    ..\entra\Report-LicenseInventory.ps1 to produce a license inventory report.
    Each row is processed independently and wrapped in try/catch so that a single
    tenant failure (bad tenant name, auth failure, network blip) does not abort
    the entire run. Per-tenant report CSVs are written as before; in addition, a
    single summary CSV recording Success/Failed status per tenant is written at
    the end for audit and retry handling.

.PARAMETER CsvPath
    Path to the input CSV file. Must contain a TenantName column.

.PARAMETER IncludeServicePlans
    Applied to every tenant. Passed through to Report-LicenseInventory.ps1 to
    include service plan details in the report.

.PARAMETER IncludeUserAssignments
    Applied to every tenant. Passed through to Report-LicenseInventory.ps1 to
    include per-user license assignment details in the report.

.EXAMPLE
    .\Invoke-BulkLicenseInventory.ps1 -CsvPath .\tenants.csv -IncludeServicePlans

    Processes every tenant listed in tenants.csv and writes per-tenant license
    inventory reports (including service plans) plus a BulkLicenseInventorySummary CSV.
#>
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [switch]$IncludeServicePlans,
    [switch]$IncludeUserAssignments
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$script:ReportsFolderRelativePath = '..\reports'
$script:TimestampFormat = 'yyyyMMddHHmmss'

$rows = Import-Csv -Path $CsvPath
$results = foreach ($row in $rows) {
    $out = Join-Path $PSScriptRoot "$($script:ReportsFolderRelativePath)\LicenseInventory_$($row.TenantName)_$(Get-Date -Format $script:TimestampFormat).csv"
    try {
        & (Join-Path $PSScriptRoot '..\entra\Report-LicenseInventory.ps1') -TenantName $row.TenantName -OutputCsv $out -IncludeServicePlans:$IncludeServicePlans -IncludeUserAssignments:$IncludeUserAssignments
        [pscustomobject]@{ TenantName=$row.TenantName; ReportPath=$out; Status='Success'; Error='' }
    }
    catch {
        [pscustomobject]@{ TenantName=$row.TenantName; ReportPath=$out; Status='Failed'; Error=$_.Exception.Message }
    }
}
$out = Join-Path (Join-Path $PSScriptRoot $script:ReportsFolderRelativePath) ("BulkLicenseInventorySummary_{0}.csv" -f (Get-Date -Format $script:TimestampFormat))
$results | Export-Csv -NoTypeInformation -Path $out
$out
