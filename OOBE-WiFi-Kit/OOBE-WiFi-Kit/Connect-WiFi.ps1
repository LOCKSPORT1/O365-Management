<#
.SYNOPSIS
    OOBE Wi-Fi worker -  imports every staged profile from the kit and connects.
    Launched by Connect-WiFi.cmd; can also be run directly.

.DESCRIPTION
    1. Finds every Wi-Fi profile XML in its own folder
    2. Imports each with 'user=all'
    3. Attempts to connect, in file order, until one succeeds
    4. Verifies and reports the interface state

    No parameters needed -  drop profile XMLs beside it and run.
#>

[CmdletBinding()]
param()

#region Configuration
$ConnectTimeoutSeconds = 20   # how long to wait for association per profile
$PollIntervalSeconds   = 2
#endregion Configuration

$kitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- 1. Discover profile XMLs ----------------------------------------------
$profileFiles = Get-ChildItem -Path $kitRoot -Filter '*.xml' -ErrorAction SilentlyContinue |
    Where-Object { (Get-Content $_.FullName -Raw) -match '<WLANProfile' }

if (-not $profileFiles) {
    Write-Host 'No Wi-Fi profile XMLs found beside this script.' -ForegroundColor Red
    Write-Host 'Stage one first with Export-WiFiProfile.ps1 (see README).' -ForegroundColor Yellow
    exit 1
}

# --- 2. Check for a wireless adapter ----------------------------------------
$wlanCheck = netsh wlan show interfaces 2>&1
if ($wlanCheck -match 'There is no wireless interface') {
    Write-Host 'No wireless interface found on this device (or radio disabled).' -ForegroundColor Red
    exit 1
}

# --- 3. Import all profiles --------------------------------------------------
$ssids = @()
foreach ($f in $profileFiles) {
    $name = ([xml](Get-Content $f.FullName -Raw)).WLANProfile.name
    Write-Host "Importing profile: $name  ($($f.Name))" -ForegroundColor Cyan
    netsh wlan add profile filename="$($f.FullName)" user=all | Out-Null
    $ssids += $name
}

# --- 4. Connect (first profile that associates wins) ------------------------
$connected = $false
foreach ($ssid in $ssids) {
    Write-Host "Connecting to '$ssid' ..." -ForegroundColor Cyan
    netsh wlan connect name="$ssid" | Out-Null

    $elapsed = 0
    while ($elapsed -lt $ConnectTimeoutSeconds) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
        $state = (netsh wlan show interfaces) -join "`n"
        if ($state -match 'State\s+:\s+connected' -and $state -match [regex]::Escape($ssid)) {
            $connected = $true
            break
        }
    }
    if ($connected) { break }
    Write-Host "  '$ssid' did not associate within $ConnectTimeoutSeconds s, trying next..." -ForegroundColor Yellow
}

# --- 5. Report ----------------------------------------------------------------
Write-Host ''
if ($connected) {
    Write-Host "=== CONNECTED to '$ssid' ===" -ForegroundColor Green
    netsh wlan show interfaces | Select-String 'SSID|State|Signal|Radio type'
    Write-Host ''
    Write-Host 'Continue OOBE -  the setup flow now has network access.' -ForegroundColor Green
    exit 0
}
else {
    Write-Host '=== NOT CONNECTED ===' -ForegroundColor Red
    Write-Host 'Checks: SSID in range? Passphrase current? 2.4/5 GHz band the adapter supports?' -ForegroundColor Yellow
    Write-Host "Manual fallback:  start ms-availablenetworks:   (opens the network flyout UI)" -ForegroundColor Yellow
    exit 1
}
