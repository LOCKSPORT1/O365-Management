<#
.SYNOPSIS
Example Azure Automation runbook entry point that runs multi-tenant bulk reports.
.DESCRIPTION
Reference pattern for wiring the toolbox's bulk workflows into an Azure Automation runbook (or
any unattended scheduler). Runs license inventory, conditional access, and Autopilot device
reports across every tenant listed in the CSV, then rolls the results into a single HTML
dashboard. Intended to be copied/adapted rather than run as-is against production tenants.
.PARAMETER TenantListCsv
Path to the CSV listing tenants to process (one row per tenant, with a TenantName column
matching entries in config\tenants.json).
.PARAMETER ReportFolder
Folder where per-tenant CSV reports are written and later scanned for the dashboard.
.PARAMETER DashboardHtmlPath
Path to write the combined HTML dashboard summarizing this run's reports.
.PARAMETER DashboardLabel
Display label shown at the top of the dashboard for this runbook run.
.EXAMPLE
.\runbooks\AzureAutomation-Example.ps1 -TenantListCsv .\templates\BulkTenantList.csv
.NOTES
Replace delegated auth with app-only auth in tenant config (config\tenants.json ->
AppRegistration.UseAppOnly) before running unattended in Azure Automation.
#>
param(
    [string]$TenantListCsv = '.\templates\BulkTenantList.csv',
    [string]$ReportFolder = '.\reports',
    [string]$DashboardHtmlPath = '.\reports\RunbookDashboard.html',
    [string]$DashboardLabel = 'Runbook-MultiTenant'
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Root of the toolbox, resolved relative to this script so the runbook works regardless of caller CWD.
$ToolboxRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Example Azure Automation / runbook entry point
# Replace delegated auth with app-only auth in tenant config before unattended use.

& (Join-Path $ToolboxRoot 'bulk\Invoke-BulkLicenseInventory.ps1') -CsvPath $TenantListCsv -IncludeServicePlans
& (Join-Path $ToolboxRoot 'bulk\Invoke-BulkConditionalAccessReport.ps1') -CsvPath $TenantListCsv
& (Join-Path $ToolboxRoot 'bulk\Invoke-BulkAutopilotReport.ps1') -CsvPath $TenantListCsv
& (Join-Path $ToolboxRoot 'reporting\New-HtmlDashboardReport.ps1') -TenantName $DashboardLabel -ReportFolder $ReportFolder -OutputHtml $DashboardHtmlPath
