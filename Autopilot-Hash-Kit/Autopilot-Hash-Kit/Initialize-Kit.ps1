<#
.SYNOPSIS
    One-time kit initializer -  stages the Get-WindowsAutopilotInfo script
    onto the USB stick so hash capture works OFFLINE at OOBE.

.DESCRIPTION
    Run this ONCE on any internet-connected machine with the USB kit
    inserted. It downloads the official Get-WindowsAutopilotInfo script from
    the PowerShell Gallery into the kit folder. After that, the capture
    scripts on the stick have no internet dependency of their own.

    Re-run occasionally to refresh to the latest Gallery version.

.PARAMETER KitPath
    The kit folder on the USB stick (where Capture-Hash.cmd lives).
    Defaults to this script's own folder -  so if you run it FROM the stick,
    no parameter is needed.

.EXAMPLE
    .\Initialize-Kit.ps1
    Run from the stick itself -  stages the script beside it.
#>

[CmdletBinding()]
param(
    [string]$KitPath = $PSScriptRoot
)

#region Configuration
$ScriptName = 'Get-WindowsAutopilotInfo'
#endregion Configuration

# Normalize bare drive letters ('E:' -> 'E:\') -  see Export-WiFiProfile lesson.
if ($KitPath -match '^[A-Za-z]:$') { $KitPath += '\' }
$KitPath = [System.IO.Path]::GetFullPath($KitPath)

Write-Host "Staging $ScriptName into $KitPath ..." -ForegroundColor Cyan

try {
    # Save-Script drops Get-WindowsAutopilotInfo.ps1 directly into the folder.
    Save-Script -Name $ScriptName -Path $KitPath -Force -ErrorAction Stop
}
catch {
    Write-Warning "Save-Script failed: $($_.Exception.Message)"
    Write-Host 'If prompted about NuGet provider or repository trust, answer Yes and re-run.' -ForegroundColor Yellow
    Write-Host "Manual alternative:  Install-Script $ScriptName ; copy from $env:ProgramFiles\WindowsPowerShell\Scripts" -ForegroundColor Yellow
    exit 1
}

$staged = Join-Path $KitPath "$ScriptName.ps1"
if (Test-Path $staged) {
    $ver = (Get-Content $staged | Select-String '\.VERSION\s+(\S+)' | Select-Object -First 1)
    Write-Host "SUCCESS: $ScriptName.ps1 staged. $ver" -ForegroundColor Green
    Write-Host 'The kit is now fully offline-capable for CSV capture.' -ForegroundColor Green
}
else {
    Write-Warning 'Staging reported success but the file is missing -  check the path.'
}
