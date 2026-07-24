<#
.SYNOPSIS
    Autopilot hash capture worker. Launched by Capture-Hash.cmd at OOBE;
    can also run on a device already in Windows.

.DESCRIPTION
    OFFLINE mode (default): captures this device's hardware hash and APPENDS
    it to AutopilotHWID.csv beside this script -  one stick accumulates a
    whole batch of devices, import the CSV into Intune once at the end.
    No network required.

    ONLINE mode (-Online): uploads the hash directly to the tenant via
    Get-WindowsAutopilotInfo's -Online path. Requires network and an
    interactive Intune-admin sign-in on the device being captured.

    Requires Get-WindowsAutopilotInfo.ps1 staged beside this script - 
    run Initialize-Kit.ps1 once from an internet-connected machine first.

.PARAMETER Online
    Upload directly to Intune instead of writing to the batch CSV.

.PARAMETER GroupTag
    Optional Autopilot Group Tag to stamp on the capture (drives dynamic
    group membership in tag-based setups). In offline mode it's written
    into the CSV; in online mode it's applied at upload.

.EXAMPLE
    .\Capture-Hash.ps1
    Append this device to the stick's batch CSV.

.EXAMPLE
    .\Capture-Hash.ps1 -GroupTag 'SALES'
    Append with a group tag.

.EXAMPLE
    .\Capture-Hash.ps1 -Online -GroupTag 'SALES'
    Direct upload with tag (network + admin sign-in required).
#>

[CmdletBinding()]
param(
    [switch]$Online,
    [string]$GroupTag
)

#region Configuration
$CsvName = 'AutopilotHWID.csv'   # batch file, lives beside this script
#endregion Configuration

$kitRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$apScript  = Join-Path $kitRoot 'Get-WindowsAutopilotInfo.ps1'
$csvPath   = Join-Path $kitRoot $CsvName

# --- Preflight ---------------------------------------------------------------
if (-not (Test-Path $apScript)) {
    Write-Host "Get-WindowsAutopilotInfo.ps1 is not staged on this kit." -ForegroundColor Red
    Write-Host "Run Initialize-Kit.ps1 once from an internet-connected machine." -ForegroundColor Yellow
    exit 1
}

$serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
Write-Host "Device serial: $serial" -ForegroundColor Cyan

# --- Duplicate guard (offline mode) ------------------------------------------
if (-not $Online -and (Test-Path $csvPath)) {
    $existing = Import-Csv $csvPath
    if ($existing | Where-Object { $_.'Device Serial Number' -eq $serial }) {
        Write-Host "Serial $serial is ALREADY in $CsvName -  skipping duplicate capture." -ForegroundColor Yellow
        Write-Host "(Delete its row from the CSV first if you need to re-capture.)" -ForegroundColor DarkGray
        exit 0
    }
}

# --- Capture ------------------------------------------------------------------
$apArgs = @{}
if ($GroupTag) { $apArgs['GroupTag'] = $GroupTag }

if ($Online) {
    Write-Host 'ONLINE mode: uploading directly to Intune (sign-in prompt incoming)...' -ForegroundColor Cyan
    & $apScript -Online @apArgs
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host 'Online upload reported a failure -  falling back is easy: re-run without "online" for CSV capture.' -ForegroundColor Yellow
        exit 1
    }
    Write-Host 'Upload complete. Allow a few minutes for the device to appear in Autopilot devices.' -ForegroundColor Green
}
else {
    Write-Host "OFFLINE mode: appending to $CsvName ..." -ForegroundColor Cyan
    & $apScript -OutputFile $csvPath -Append @apArgs

    if (Test-Path $csvPath) {
        $count = (Import-Csv $csvPath).Count
        Write-Host ''
        Write-Host "=== CAPTURED ===" -ForegroundColor Green
        Write-Host "Batch file now holds $count device(s): $csvPath" -ForegroundColor Green
        Write-Host 'Import at: Intune > Devices > Enrollment > Windows Autopilot > Devices > Import' -ForegroundColor Cyan
    }
    else {
        Write-Host 'Capture ran but the CSV was not created -  check the output above.' -ForegroundColor Red
        exit 1
    }
}
