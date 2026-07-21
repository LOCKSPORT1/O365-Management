<#
.SYNOPSIS
    Reports on Intune-managed devices that have not synced within a configurable number of days.

.DESCRIPTION
    Connects to Microsoft Graph for the specified tenant, retrieves all Intune managed
    devices, and exports the ones whose LastSyncDateTime is older than the configured
    inactivity threshold to a CSV report. Read-only — does not modify or act on any
    devices. Intended to be run standalone or dot-sourced by Cleanup-StaleDevices.ps1
    to produce a pre-cleanup snapshot of candidates.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. 'Tenant-Example-NA').

.PARAMETER InactiveDays
    Number of days since last Intune sync before a device is considered stale.
    Defaults to the value in the CONFIGURATION block below.

.PARAMETER OutputCsv
    Path to the CSV report file to create. Defaults to the value in the CONFIGURATION
    block below (relative to the toolbox root's reports folder).

.EXAMPLE
    .\Report-StaleDevices.ps1 -TenantName 'Tenant-Example-NA'

.EXAMPLE
    .\Report-StaleDevices.ps1 -TenantName 'Tenant-Example-NA' -InactiveDays 60 -OutputCsv 'C:\Reports\StaleDevices.csv'
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [int]$InactiveDays,
    [string]$OutputCsv
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Number of days since last Intune sync before a device is considered stale
$DefaultInactiveDays = 30
# Default CSV output path (relative to the toolbox root) when -OutputCsv is not supplied
$DefaultOutputCsv = Join-Path (Join-Path $PSScriptRoot '..\reports') 'StaleDevices.csv'

if (-not $PSBoundParameters.ContainsKey('InactiveDays')) { $InactiveDays = $DefaultInactiveDays }
if (-not $PSBoundParameters.ContainsKey('OutputCsv')) { $OutputCsv = $DefaultOutputCsv }

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectGraph -ConnectIntune

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

# NOTE: Get-MgDeviceManagementManagedDevice does not reliably support server-side
# $filter on lastSyncDateTime across all Graph SDK versions/tenants, so devices are
# retrieved in full and filtered client-side for consistency with Cleanup-StaleDevices.ps1.
$cutoff = (Get-Date).ToUniversalTime().AddDays(-$InactiveDays)
$allDevices = Get-MgDeviceManagementManagedDevice -All
$devices = $allDevices | Where-Object { $_.LastSyncDateTime -and ([datetime]$_.LastSyncDateTime).ToUniversalTime() -lt $cutoff }

$rows = foreach ($d in $devices) {
    [pscustomobject]@{
        TenantName = $TenantName
        DeviceName = $d.DeviceName
        UserPrincipalName = $d.UserPrincipalName
        Id = $d.Id
        OperatingSystem = $d.OperatingSystem
        ComplianceState = $d.ComplianceState
        ManagementAgent = $d.ManagementAgent
        LastSyncDateTime = $d.LastSyncDateTime
        EnrolledDateTime = $d.EnrolledDateTime
    }
}
$rows | Export-Csv -NoTypeInformation -Path $OutputCsv
Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Stale device report exported to $OutputCsv"
