<#
.SYNOPSIS
    Stage a Wi-Fi profile onto a USB deployment kit for use at Windows OOBE.

.DESCRIPTION
    Run this ONCE, on any machine already connected to the target Wi-Fi
    network, with the USB kit inserted. It exports the Wi-Fi profile with the
    key in clear text (required -  an encrypted key only re-imports on the
    machine that exported it) and drops it next to Connect-WiFi.cmd on the
    USB stick.

    SECURITY NOTE: the exported XML contains the Wi-Fi passphrase in PLAIN
    TEXT. Treat the USB kit like a written-down password: technician
    possession only, never a shared drive, wipe/rotate if the stick is lost.

.PARAMETER SsidName
    The Wi-Fi profile (network) name to export. If omitted, lists available
    profiles on this machine and prompts.

.PARAMETER KitPath
    Root of the USB kit (where Connect-WiFi.cmd lives). If omitted, prompts.

.EXAMPLE
    .\Export-WiFiProfile.ps1 -SsidName 'CORP-SECURE' -KitPath 'E:\'

.NOTES
    Requires: run elevated on a machine that has connected to the network
              at least once (the profile must exist locally).
#>

[CmdletBinding()]
param(
    [string]$SsidName,
    [string]$KitPath
)

#region Configuration
# Subfolder on the kit where profiles are stored. Connect-WiFi looks here
# first, then in its own folder. Keep as '' to store beside the scripts.
$ProfileSubfolder = ''
#endregion Configuration

# --- Elevation check -------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning 'Not elevated. netsh may refuse key=clear export. Re-run as Administrator.'
}

# --- Pick the profile ------------------------------------------------------
if (-not $SsidName) {
    Write-Host 'Wi-Fi profiles on this machine:' -ForegroundColor Cyan
    netsh wlan show profiles | Select-String 'All User Profile' | ForEach-Object {
        ($_ -split ':', 2)[1].Trim()
    } | ForEach-Object { Write-Host " - $_" }
    $SsidName = Read-Host 'Enter the profile name to export'
}

# --- Pick the destination --------------------------------------------------
if (-not $KitPath) {
    $KitPath = Read-Host 'Enter the USB kit root path (e.g. E:\)'
}
# Normalize a bare drive letter ('E:') to the root ('E:\'). Without this,
# PowerShell treats 'E:' as drive-RELATIVE (the current directory on E:)
# while netsh treats it as the root -  and the verification looks in the
# wrong place. Also resolve to a full path so both tools agree.
if ($KitPath -match '^[A-Za-z]:$') { $KitPath += '\' }
$KitPath = [System.IO.Path]::GetFullPath($KitPath)
$dest = if ($ProfileSubfolder) { Join-Path $KitPath $ProfileSubfolder } else { $KitPath }
if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }

# --- Export ----------------------------------------------------------------
Write-Host "Exporting profile '$SsidName' (key in clear) to $dest ..." -ForegroundColor Cyan
$result = netsh wlan export profile name="$SsidName" key=clear folder="$dest" 2>&1
Write-Host $result

$exported = Get-ChildItem -Path $dest -Filter '*.xml' |
    Where-Object { (Get-Content $_.FullName -Raw) -match "<name>$([regex]::Escape($SsidName))</name>" }

if ($exported) {
    Write-Host ''
    Write-Host "SUCCESS: $($exported.Name) staged on the kit." -ForegroundColor Green
    Write-Host 'Reminder: this file contains the Wi-Fi passphrase in plain text.' -ForegroundColor Yellow
    Write-Host 'At OOBE: Shift+F10  ->  D:\Connect-WiFi.cmd   (adjust drive letter)' -ForegroundColor Cyan
}
else {
    Write-Warning 'Export did not produce the expected XML. Check the profile name and elevation.'
}
