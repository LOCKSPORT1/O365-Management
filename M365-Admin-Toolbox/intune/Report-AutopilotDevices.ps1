<#
.SYNOPSIS
    Reports on all Windows Autopilot device identities registered in a tenant.

.DESCRIPTION
    Connects to Microsoft Graph for the specified tenant, retrieves every Windows
    Autopilot device identity, and exports key details (serial number, group tag,
    manufacturer, model, enrollment state, last contact) to a CSV report. Read-only —
    does not modify any devices or Autopilot registrations.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. 'Tenant-Example-NA').

.PARAMETER OutputCsv
    Path to the CSV report file to create. Defaults to the value in the CONFIGURATION
    block below (relative to the toolbox root's reports folder).

.EXAMPLE
    .\Report-AutopilotDevices.ps1 -TenantName 'Tenant-Example-NA'

.EXAMPLE
    .\Report-AutopilotDevices.ps1 -TenantName 'Tenant-Example-NA' -OutputCsv 'C:\Reports\Autopilot.csv'
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$OutputCsv
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Default CSV output path (relative to the toolbox root) when -OutputCsv is not supplied
$DefaultOutputCsv = Join-Path (Join-Path $PSScriptRoot '..\reports') 'AutopilotDevices.csv'

if (-not $PSBoundParameters.ContainsKey('OutputCsv')) { $OutputCsv = $DefaultOutputCsv }

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectGraph -ConnectIntune

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

$devices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All
$rows = foreach ($d in $devices) {
    [pscustomobject]@{
        TenantName = $TenantName
        Id = $d.Id
        SerialNumber = $d.SerialNumber
        GroupTag = $d.GroupTag
        PurchaseOrderIdentifier = $d.PurchaseOrderIdentifier
        Manufacturer = $d.Manufacturer
        Model = $d.Model
        EnrollmentState = $d.EnrollmentState
        LastContactedDateTime = $d.LastContactedDateTime
    }
}
$rows | Export-Csv -NoTypeInformation -Path $OutputCsv
Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Autopilot device report exported to $OutputCsv"
