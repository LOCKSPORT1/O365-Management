<#
.SYNOPSIS
    Collects connected monitor and docking station inventory and writes it to
    NinjaRMM custom fields so it can be reported on centrally.

.DESCRIPTION
    - Monitors: read via the WmiMonitorID class (root\wmi), which exposes EDID-derived
      manufacturer code, model (UserFriendlyName), and serial number for every currently
      connected display. This is the same data Windows itself uses for display identification.
    - Docking stations: there is no single universal WMI class for USB-C/Thunderbolt docks.
      This script enumerates PnP devices, flags anything that (a) matches a known dock-brand
      USB vendor ID, or (b) has "dock" in its friendly name / bus-reported description, then
      GROUPS matches by VID_xxxx&PID_yyyy. This matters because one physical dock usually
      enumerates as several separate Windows PnP entries (a video function, an audio
      function, an ethernet function, an internal hub, and a composite parent) — without
      grouping, one dock on a desk shows up as 5-10 rows. Within each group it picks the
      most descriptive product name, the most specific manufacturer string, and the first
      real serial number found among the group's members (composite parent nodes usually
      carry the true serial even when individual function/interface nodes don't).
      NOTE: not all docks expose a true serial number over USB — some only expose a
      vendor/product ID with no per-unit serial. Where no serial is found the field will
      say "Not exposed by device". Also note the Manufacturer field often reflects the USB
      chipset vendor (e.g. "DisplayLink") rather than the box brand (e.g. "Plugable") —
      the Model field is where the actual product name/number shows up.

    Results are written as JSON strings into two NinjaRMM custom fields:
        dockInventoryjson
        monitorInventoryjson
    (Ninja lowercases the "JSON" suffix in the field Name even if you capitalize
    it in the Label, so match the field names exactly as Ninja created them —
    check Administration > Devices > Custom Fields to confirm.)
    Create these as Multi-Line Text, device-scoped custom fields in Ninja before running
    this as a scheduled script/policy. See SETUP_GUIDE.md for exact steps.

.NOTES
    Run with SYSTEM/admin rights (Ninja scripts run as SYSTEM by default, which is fine).
    Safe to run repeatedly; it always reflects current state, not history.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-MonitorInventory {
    $result = @()
    try {
        $monitors = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue
    } catch {
        $monitors = @()
    }

    foreach ($m in $monitors) {
        $manufacturer = -join ($m.ManufacturerName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
        $model        = -join ($m.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
        $serial       = -join ($m.SerialNumberID    | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })

        if ([string]::IsNullOrWhiteSpace($model))  { $model  = "Unknown model" }
        if ([string]::IsNullOrWhiteSpace($serial)) { $serial = "Not exposed by device" }

        $result += [PSCustomObject]@{
            Manufacturer = $manufacturer.Trim()
            Model        = $model.Trim()
            SerialNumber = $serial.Trim()
            InstanceName = $m.InstanceName
        }
    }
    return $result
}

function Get-DockInventory {
    # Vendor IDs specific enough to dock / multi-display-adapter product lines.
    # Deliberately excludes generic hub/ethernet chipset VIDs (VIA Labs, Realtek,
    # ASIX, etc.) since those chips show up in tons of unrelated USB accessories
    # (standalone hubs, webcams, dongles) and caused false-positive dock rows
    # when tested against a real machine.
    $knownDockVendorIds = @(
        'VID_413C',  # Dell
        'VID_17EF',  # Lenovo
        'VID_03F0',  # HP
        'VID_2188',  # Kensington
        'VID_17E9'   # DisplayLink chipset (used by Plugable/StarTech/Targus/many multi-monitor docks)
    )

    # Generic Windows-assigned names that never identify the actual product -
    # used to prefer a better name when one is available within a device group.
    $genericNamePattern = '^(USB Composite Device|Generic .*Hub|USB Billboard Device|USB Input Device|USB Root Hub.*|Composite USB Device)$'
    $genericMfrPattern  = '^(\(Standard.*|Microsoft|\(Generic.*)$'

    $pnpDevices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue

    $vendorMatches = $pnpDevices | Where-Object {
        $devId = $_.DeviceID
        foreach ($vid in $knownDockVendorIds) {
            if ($devId -match $vid) { return $true }
        }
        return $false
    }

    $nameMatches = $pnpDevices | Where-Object {
        ($_.Name -match '(?i)dock') -or ($_.Description -match '(?i)dock')
    }

    $allMatches = @($vendorMatches) + @($nameMatches) | Sort-Object DeviceID -Unique

    # Group by VID_xxxx&PID_yyyy so the multiple USB interfaces/functions that one
    # physical dock enumerates as (video, audio, ethernet, hub, composite parent)
    # collapse into a single reported device instead of many duplicate rows.
    $groups = [ordered]@{}
    foreach ($d in $allMatches) {
        if ($d.DeviceID -match '(VID_[0-9A-F]{4}&PID_[0-9A-F]{4})') {
            $key = $Matches[1]
        } else {
            $key = $d.DeviceID
        }
        if (-not $groups.Contains($key)) { $groups[$key] = New-Object System.Collections.Generic.List[object] }
        $groups[$key].Add($d)
    }

    $result = @()
    foreach ($key in $groups.Keys) {
        $members = $groups[$key]

        $named = $members | Where-Object { $_.Name -and ($_.Name -notmatch $genericNamePattern) }
        $model = if ($named) { ($named | Select-Object -First 1).Name } else { ($members | Select-Object -First 1).Name }

        $namedMfr = $members | Where-Object { $_.Manufacturer -and ($_.Manufacturer -notmatch $genericMfrPattern) }
        $manufacturer = if ($namedMfr) { ($namedMfr | Select-Object -First 1).Manufacturer } else { ($members | Select-Object -First 1).Manufacturer }
        if (-not $manufacturer) { $manufacturer = "Unknown" }

        # Find a real serial number from any member of the group. Composite parent
        # nodes (instance ID with no "&MI_xx" segment) usually carry the true serial
        # even when individual function/interface child nodes don't.
        $serial = "Not exposed by device"
        foreach ($m in $members) {
            if ($m.DeviceID -match '\\([A-Za-z0-9]{6,})$') {
                $candidateSerial = $Matches[1]
                if ($candidateSerial -notmatch '^0+$' -and $candidateSerial.Length -ge 6) {
                    $serial = $candidateSerial
                    break
                }
            }
        }

        $result += [PSCustomObject]@{
            Manufacturer = $manufacturer
            Model        = $model
            SerialNumber = $serial
            DeviceKey    = $key
        }
    }
    return $result
}

# --- Collect ---
$monitorInventory = Get-MonitorInventory
$dockInventory     = Get-DockInventory

$monitorJson = $monitorInventory | ConvertTo-Json -Compress -Depth 4
$dockJson    = $dockInventory     | ConvertTo-Json -Compress -Depth 4

if (-not $monitorJson) { $monitorJson = "[]" }
if (-not $dockJson)    { $dockJson    = "[]" }

Write-Output "Monitors found: $($monitorInventory.Count)"
Write-Output $monitorJson
Write-Output "Dock candidates found: $($dockInventory.Count)"
Write-Output $dockJson

# --- Write to Ninja custom fields ---
# Ninja-Property-Set is provided by the NinjaRMM agent automatically when a script
# runs through the Ninja platform. It is not a standard PowerShell cmdlet, so this
# will only work when executed as a Ninja scheduled script/policy, not standalone.
if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) {
    Ninja-Property-Set monitorInventoryjson $monitorJson
    Ninja-Property-Set dockInventoryjson $dockJson
    Write-Output "Custom fields updated via Ninja-Property-Set."
} else {
    Write-Warning "Ninja-Property-Set not found. Run this script through NinjaRMM (scheduled script/policy) so results get written to custom fields. Output above can still be reviewed manually."
}
