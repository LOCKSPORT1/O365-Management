<#
.SYNOPSIS
    Pulls a full Intune managed device inventory with compliance state,
    last check-in, primary user, and OS - exports to CSV.

.DESCRIPTION
    Useful for a monthly device hygiene pass: stale devices (no check-in in
    N days), noncompliant devices, and devices with no assigned primary
    user (often orphaned/kiosk/re-imaged machines worth investigating).

.NOTES
    Self-connects to Graph automatically if not already connected
    (see -AuthMode param; defaults to Interactive).
    Requires Graph scope DeviceManagementManagedDevices.Read.All at minimum.
#>

[CmdletBinding()]
param(
    # ============================================================
    # CONFIGURATION - adjust these values for your environment
    # ============================================================
    # Devices with no check-in for longer than this (days) are flagged IsStale.
    [int]$StaleThresholdDays = 30,

    # CSV export path; defaults to current dir with today's date.
    [string]$ExportPath = ".\IntuneDeviceInventory_$(Get-Date -Format 'yyyyMMdd').csv",

    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

Write-Host "Pulling managed device inventory from Intune..." -ForegroundColor Cyan
$devices = Get-MgDeviceManagementManagedDevice -All

$staleCutoff = (Get-Date).AddDays(-$StaleThresholdDays)

$report = foreach ($d in $devices) {
    [PSCustomObject]@{
        DeviceName        = $d.DeviceName
        PrimaryUser       = $d.UserPrincipalName
        OS                = $d.OperatingSystem
        OSVersion         = $d.OsVersion
        ComplianceState   = $d.ComplianceState
        ManagementState   = $d.ManagementState
        LastSyncDateTime  = $d.LastSyncDateTime
        EnrolledDateTime  = $d.EnrolledDateTime
        SerialNumber      = $d.SerialNumber
        Model             = $d.Model
        Manufacturer      = $d.Manufacturer
        IsStale           = ($d.LastSyncDateTime -lt $staleCutoff)
        NoPrimaryUser     = [string]::IsNullOrEmpty($d.UserPrincipalName)
        AzureADDeviceId   = $d.AzureAdDeviceId
        IntuneDeviceId    = $d.Id
    }
}

$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Exported $($report.Count) devices to $ExportPath" -ForegroundColor Green

$staleCount = ($report | Where-Object IsStale).Count
$noncompliantCount = ($report | Where-Object { $_.ComplianceState -ne 'compliant' }).Count
$orphanCount = ($report | Where-Object NoPrimaryUser).Count

Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "  Total devices:        $($report.Count)"
Write-Host "  Stale (>$StaleThresholdDays days no check-in): $staleCount"
Write-Host "  Noncompliant:         $noncompliantCount"
Write-Host "  No primary user:      $orphanCount"
