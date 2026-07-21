<#
.SYNOPSIS
    Finds stale Entra ID device objects (hybrid-joined, Entra-joined, or
    registered) that haven't checked in within N days, and optionally
    disables or deletes them. Broader than the Intune-specific inventory
    in 03-DeviceLifecycle - this covers ALL device objects in Entra ID,
    including ones that never enrolled in Intune (older hybrid-joined
    machines, stale registered personal devices, etc.).

.DESCRIPTION
    Stale device objects accumulate quietly - decommissioned laptops that
    were never formally removed, re-imaged machines that created a
    duplicate object, personal devices someone registered once and never
    used again. Each one is still a valid object Conditional Access and
    device-based Compliance policies have to evaluate against, and a
    device-based dynamic group has to consider.

.PARAMETER StaleThresholdDays
    Number of days without a sign-in before a device is flagged stale
    (default 180).

.PARAMETER Action
    ReportOnly (default, no changes made), Disable, or Delete. Disable/
    Delete additionally require -Confirmed and honor -WhatIf/-Confirm
    via SupportsShouldProcess.

.PARAMETER Confirmed
    Required gate for -Action Disable or -Action Delete. Without it, the
    script refuses to proceed past the report stage even if -Action is
    set, so a mistyped/scheduled run can never take action unattended.

.PARAMETER ExportPath
    Path to write the CSV report to.

.PARAMETER AuthMode
    Interactive, AppSecret, or Certificate - passed through to
    Assert-M365Connection. Defaults to Interactive.

.EXAMPLE
    # Review first - always report-only unless both -Action and -Confirmed are supplied
    .\Get-StaleEntraDeviceCleanup.ps1 -StaleThresholdDays 180

.EXAMPLE
    # Clean up once reviewed
    .\Get-StaleEntraDeviceCleanup.ps1 -StaleThresholdDays 180 -Action Disable -Confirmed

.EXAMPLE
    # Preview exactly what would be disabled without making changes
    .\Get-StaleEntraDeviceCleanup.ps1 -Action Disable -Confirmed -WhatIf

.NOTES
    Requires Graph scope Device.ReadWrite.All if using -Disable or
    -Delete. Read-only reporting only needs Device.Read.All.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # ============================================================
    # CONFIGURATION - adjust these values for your environment
    # ============================================================
    # Number of days without a sign-in before a device is flagged stale.
    [int]$StaleThresholdDays = 180,

    # ReportOnly (default/safe), Disable, or Delete. Disable/Delete require -Confirmed.
    [ValidateSet("ReportOnly","Disable","Delete")]
    [string]$Action = "ReportOnly",

    # Required in addition to -Action Disable/Delete before any change is made.
    [switch]$Confirmed,

    # Output path for the CSV report.
    [string]$ExportPath = ".\StaleDeviceReport_$(Get-Date -Format 'yyyyMMdd').csv",

    # Auth mode passed through to Assert-M365Connection (Interactive/AppSecret/Certificate).
    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

if ($Action -ne "ReportOnly" -and -not $Confirmed) {
    Write-Error "-Action $Action requires -Confirmed. Run with -Action ReportOnly first to review scope."
    return
}

$cutoff = (Get-Date).AddDays(-$StaleThresholdDays)
Write-Host "Scanning Entra device objects for no activity since before $($cutoff.ToShortDateString())..." -ForegroundColor Cyan

try {
    $devices = Get-MgDevice -All -Property Id,DisplayName,DeviceId,OperatingSystem,ApproximateLastSignInDateTime,AccountEnabled,TrustType,IsCompliant,IsManaged
}
catch {
    Write-Error "Failed to retrieve device objects from Graph: $($_.Exception.Message)"
    return
}

$stale = $devices | Where-Object {
    (-not $_.ApproximateLastSignInDateTime) -or ($_.ApproximateLastSignInDateTime -lt $cutoff)
}

$report = $stale | ForEach-Object {
    [PSCustomObject]@{
        DisplayName    = $_.DisplayName
        OS             = $_.OperatingSystem
        TrustType      = $_.TrustType          # AzureAd, ServerAd (hybrid), Workplace (registered)
        LastSignIn     = $_.ApproximateLastSignInDateTime
        AccountEnabled = $_.AccountEnabled
        IsManaged      = $_.IsManaged
        DeviceObjectId = $_.Id
    }
}

$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Exported $($report.Count) stale device(s) to $ExportPath" -ForegroundColor Green
$report | Format-Table DisplayName, OS, TrustType, LastSignIn, AccountEnabled -AutoSize

if ($Action -eq "ReportOnly") {
    Write-Host "`nReport-only run. No changes made. Re-run with -Action Disable or -Action Delete -Confirmed once reviewed." -ForegroundColor Cyan
    return
}

$actionFailures = @()
foreach ($d in $stale) {
    try {
        if ($Action -eq "Disable") {
            if ($PSCmdlet.ShouldProcess($d.DisplayName, "Disable device")) {
                Update-MgDevice -DeviceId $d.Id -AccountEnabled:$false
                Write-Host "[OK] Disabled: $($d.DisplayName)" -ForegroundColor Yellow
            }
        }
        elseif ($Action -eq "Delete") {
            if ($PSCmdlet.ShouldProcess($d.DisplayName, "Delete device object")) {
                Remove-MgDevice -DeviceId $d.Id
                Write-Host "[OK] Deleted: $($d.DisplayName)" -ForegroundColor Red
            }
        }
    }
    catch {
        Write-Warning "[FAILED] $Action on $($d.DisplayName): $($_.Exception.Message)"
        $actionFailures += $d.DisplayName
    }
}

if ($actionFailures.Count -gt 0) {
    Write-Host "`n$($actionFailures.Count) device action(s) failed - review and retry individually: $($actionFailures -join ', ')" -ForegroundColor Red
}
