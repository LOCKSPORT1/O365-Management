<#
.SYNOPSIS
Example daily scheduled task that runs the full set of multi-tenant bulk reports.
.DESCRIPTION
Reference pattern for a daily scheduled task: runs license inventory, shared mailbox audit,
stale device, Teams inventory, SharePoint site, Autopilot, and conditional access reports for
every tenant listed in the CSV, then builds a combined HTML dashboard. Meant to be registered
via scheduled-tasks\Register-AdminToolboxScheduledTask.ps1 or an equivalent scheduler.
.PARAMETER TenantListCsv
Path to the CSV listing tenants to process (one row per tenant, with a TenantName column
matching entries in config\tenants.json).
.PARAMETER ReportFolder
Folder where per-tenant CSV reports are written and later scanned for the dashboard.
.PARAMETER DashboardHtmlPath
Path to write the combined HTML dashboard summarizing this run's reports.
.PARAMETER DashboardLabel
Display label shown at the top of the dashboard for this scheduled run.
.PARAMETER StaleDeviceInactiveDays
Number of days of inactivity before a device is considered stale in the device report.
.EXAMPLE
.\scheduled-tasks\Example-DailyReporting.ps1 -TenantListCsv .\templates\BulkTenantList.csv
#>
param(
    [string]$TenantListCsv = '.\templates\BulkTenantList.csv',
    [string]$ReportFolder = '.\reports',
    [string]$DashboardHtmlPath = '.\reports\AdminDashboardReport.html',
    [string]$DashboardLabel = 'MultiTenant',
    [int]$StaleDeviceInactiveDays = 45
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Root of the toolbox, resolved relative to this script so the task works regardless of the scheduler's working directory.
$ToolboxRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

& (Join-Path $ToolboxRoot 'bulk\Invoke-BulkLicenseInventory.ps1') -CsvPath $TenantListCsv -IncludeServicePlans -IncludeUserAssignments
& (Join-Path $ToolboxRoot 'bulk\Invoke-BulkSharedMailboxAudit.ps1') -CsvPath $TenantListCsv -IncludeSendAs
& (Join-Path $ToolboxRoot 'bulk\Invoke-BulkStaleDeviceReport.ps1') -CsvPath $TenantListCsv -InactiveDays $StaleDeviceInactiveDays
& (Join-Path $ToolboxRoot 'bulk\Invoke-BulkTeamsInventory.ps1') -CsvPath $TenantListCsv -IncludeOwners
& (Join-Path $ToolboxRoot 'bulk\Invoke-BulkSharePointSites.ps1') -CsvPath $TenantListCsv
& (Join-Path $ToolboxRoot 'bulk\Invoke-BulkAutopilotReport.ps1') -CsvPath $TenantListCsv
& (Join-Path $ToolboxRoot 'bulk\Invoke-BulkConditionalAccessReport.ps1') -CsvPath $TenantListCsv
& (Join-Path $ToolboxRoot 'reporting\New-HtmlDashboardReport.ps1') -TenantName $DashboardLabel -ReportFolder $ReportFolder -OutputHtml $DashboardHtmlPath
