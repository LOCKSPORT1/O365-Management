<#
.SYNOPSIS
Writes a starter scaffold file documenting next steps for Defender for Office 365 data collection.
.DESCRIPTION
This script does not call any Defender cmdlets itself. It generates a placeholder text file
noting the intended purpose and reminders for building out real Defender for Office 365
reporting (e.g. threat/quarantine/policy data) for a tenant, since the specific cmdlets and
licensing vary by environment.
.PARAMETER TenantName
Tenant name from config\tenants.json.
.PARAMETER OutputTxt
Path to write the scaffold text file.
.EXAMPLE
.\security\Export-DefenderO365Scaffold.ps1 -TenantName Tenant-Example-NA
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$OutputTxt = '.\reports\DefenderO365Scaffold.txt'
)

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
$outputFolder = Split-Path $OutputTxt -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

try {
    $content = @"
TenantName: $TenantName
Purpose: starter scaffold for Defender for Office 365 data collection.
Notes:
- Validate your Defender workload cmdlets and licensing in the tenant.
- Extend this scaffold with the specific Defender cmdlets or APIs approved in your environment.
- Pair outputs with compliance audit exports and message hygiene reports.
"@
    Set-Content -Path $OutputTxt -Value $content -Encoding UTF8
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Defender O365 scaffold written to $OutputTxt"
}
catch {
    Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "Defender O365 scaffold write failed: $($_.Exception.Message)"
    throw
}
