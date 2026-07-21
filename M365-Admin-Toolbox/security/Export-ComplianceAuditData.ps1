<#
.SYNOPSIS
Exports unified audit log records for a tenant to CSV.
.DESCRIPTION
Connects to Exchange Online for the given tenant and runs Search-UnifiedAuditLog over the
specified date range and record type, exporting the results to CSV. Useful for ad hoc
investigations and for feeding the compliance/security reporting pipeline.
.PARAMETER TenantName
Tenant name from config\tenants.json.
.PARAMETER StartDate
Start of the audit log search window.
.PARAMETER EndDate
End of the audit log search window.
.PARAMETER OutputCsv
Path to write the exported CSV of audit records.
.PARAMETER RecordType
Unified audit log record type to search for (see Search-UnifiedAuditLog -RecordType values).
.PARAMETER ResultSize
Maximum number of records to return in a single search. Search-UnifiedAuditLog caps this at
5000; if you expect more results in the window, narrow the date range or run multiple searches.
.EXAMPLE
.\security\Export-ComplianceAuditData.ps1 -TenantName Tenant-Example-NA -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date)
.EXAMPLE
.\security\Export-ComplianceAuditData.ps1 -TenantName Tenant-Example-Cloud -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -RecordType 'AzureActiveDirectory' -OutputCsv .\reports\AadAudit.csv
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [Parameter(Mandatory)][datetime]$StartDate,
    [Parameter(Mandatory)][datetime]$EndDate,
    [string]$OutputCsv = '.\reports\ComplianceAuditData.csv',
    [string]$RecordType = 'ExchangeAdmin',
    [int]$ResultSize = 5000
)

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectExchange

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

try {
    $results = Search-UnifiedAuditLog -StartDate $StartDate -EndDate $EndDate -RecordType $RecordType -ResultSize $ResultSize
    if ($results.Count -ge $ResultSize) {
        Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "Result count reached ResultSize ($ResultSize); results may be truncated. Narrow the date range or run additional searches."
    }
    $rows = foreach ($r in $results) {
        [pscustomobject]@{
            TenantName = $TenantName
            CreationDate = $r.CreationDate
            UserIds = ($r.UserIds -join ';')
            Operations = $r.Operations
            RecordType = $r.RecordType
            AuditData = $r.AuditData
        }
    }
    $rows | Export-Csv -NoTypeInformation -Path $OutputCsv
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Compliance audit export written to $OutputCsv"
}
catch {
    Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "Compliance audit export failed: $($_.Exception.Message)"
    throw
}
