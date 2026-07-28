<#
.SYNOPSIS
    Audits Intune-managed Windows devices for primary user mismatches based on
    actual Windows sign-in frequency over a lookback window, and optionally fixes them.

.DESCRIPTION
    Pulls all interactive 'Windows Sign In' events from Entra sign-in logs for the
    lookback period, groups them by device, and determines the most frequent
    interactive user per device. Compares that user against the Intune primary user
    (userPrincipalName on the managedDevice). Devices where the dominant actual user
    does not match the assigned primary user are flagged, with the suggested
    replacement user and supporting sign-in counts.

    Run with -Fix to automatically reassign the primary user on flagged devices
    (uses POST /beta/deviceManagement/managedDevices/{id}/users/$ref).

    Notes:
    - Sign-in log retention is 30 days on Entra ID P1/P2. Keep LookbackDays <= 30.
    - Technician/admin accounts and shared devices can be excluded via config below.
    - A device is only flagged when the top user meets BOTH the minimum sign-in
      count and the dominance percentage, to avoid noise from one-off logons.

.PARAMETER Fix
    Reassign the Intune primary user on mismatched devices to the most frequent user.

.PARAMETER LookbackDays
    Number of days of sign-in history to evaluate (default 14, max 30 with P1).

.EXAMPLE
    .\Invoke-PrimaryUserAudit.ps1
    Audit only; writes CSV report to .\PrimaryUserAudit_<date>.csv

.EXAMPLE
    .\Invoke-PrimaryUserAudit.ps1 -Fix -LookbackDays 7
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Fix,
    [switch]$Force,   # with -Fix: skip per-device Yes/No prompts and fix everything flagged
    [ValidateRange(1, 30)]
    [int]$LookbackDays = 14
)

#region Configuration
# UPNs (or UPN wildcard patterns) to ignore as candidate "real" users.
# Add your technician/admin/service accounts here.
$ExcludedUserPatterns = @(
    'admin*'
    '*-adm@*'
    'svc-*'
    # 'technician@yourdomain.com'   # <-- add technician UPNs
)

# Device name patterns to skip entirely (kiosks, shared shop-floor PCs, conference rooms)
$ExcludedDevicePatterns = @(
    # 'KIOSK*'
    # 'SHARED*'
)

# Flagging thresholds
$MinimumSignIns   = 5     # top user must have at least this many interactive sign-ins
$DominancePercent = 60    # top user must account for at least this % of the device's sign-ins

# Graph scopes. DeviceManagementManagedDevices.ReadWrite.All only needed for -Fix,
# but requesting it up front avoids a re-consent mid-run.
$GraphScopes = @(
    'DeviceManagementManagedDevices.ReadWrite.All'
    'AuditLog.Read.All'
    'User.Read.All'
    'Directory.Read.All'
)

$ReportPath = Join-Path (Get-Location) ("PrimaryUserAudit_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
#endregion Configuration

#region Connect
$requiredModules = @('Microsoft.Graph.Authentication')
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Host "Installing module $m..." -ForegroundColor Yellow
        Install-Module $m -Scope CurrentUser -Force -AllowClobber
    }
}
Import-Module Microsoft.Graph.Authentication

$ctx = Get-MgContext
if (-not $ctx -or ($GraphScopes | Where-Object { $_ -notin $ctx.Scopes })) {
    Connect-MgGraph -Scopes $GraphScopes -NoWelcome
}
#endregion Connect

#region Helpers
function Invoke-GraphGetAll {
    <# Pages through a Graph GET and returns all values. #>
    param([Parameter(Mandatory)][string]$Uri)
    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        if ($resp.value) { $results.AddRange([object[]]$resp.value) }
        $next = $resp.'@odata.nextLink'
    }
    return $results
}

function Test-PatternMatch {
    param([string]$Value, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Value -like $p) { return $true } }
    return $false
}
#endregion Helpers

#region Gather managed devices
Write-Host "Retrieving Intune-managed Windows devices..." -ForegroundColor Cyan
$deviceUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices" +
             "?`$filter=operatingSystem eq 'Windows'" +
             "&`$select=id,deviceName,azureADDeviceId,userPrincipalName,userId,lastSyncDateTime"
$managedDevices = Invoke-GraphGetAll -Uri $deviceUri

# Index by Entra device ID (sign-in logs reference azureADDeviceId, not the Intune object id)
$deviceMap = @{}
foreach ($d in $managedDevices) {
    if ($d.azureADDeviceId -and $d.azureADDeviceId -ne '00000000-0000-0000-0000-000000000000') {
        $deviceMap[$d.azureADDeviceId] = $d
    }
}
Write-Host ("  {0} Windows devices retrieved." -f $managedDevices.Count)
#endregion Gather managed devices

#region Gather sign-ins
$since = (Get-Date).AddDays(-$LookbackDays).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Write-Host "Retrieving 'Windows Sign In' events since $since (this can take a few minutes)..." -ForegroundColor Cyan

$signInUri = "https://graph.microsoft.com/v1.0/auditLogs/signIns" +
             "?`$filter=createdDateTime ge $since and appDisplayName eq 'Windows Sign In' and status/errorCode eq 0" +
             "&`$select=userPrincipalName,userId,createdDateTime,deviceDetail"
$signIns = Invoke-GraphGetAll -Uri $signInUri
Write-Host ("  {0} successful Windows sign-in events retrieved." -f $signIns.Count)
#endregion Gather sign-ins

#region Analyze
Write-Host "Analyzing sign-in frequency per device..." -ForegroundColor Cyan

# deviceId -> hashtable(upn -> @{Count; UserId})
$usage = @{}
foreach ($s in $signIns) {
    $devId = $s.deviceDetail.deviceId
    if ([string]::IsNullOrWhiteSpace($devId)) { continue }
    if (-not $deviceMap.ContainsKey($devId)) { continue }
    $upn = $s.userPrincipalName.ToLower()
    if (Test-PatternMatch -Value $upn -Patterns $ExcludedUserPatterns) { continue }

    if (-not $usage.ContainsKey($devId)) { $usage[$devId] = @{} }
    if (-not $usage[$devId].ContainsKey($upn)) {
        $usage[$devId][$upn] = [pscustomobject]@{ Count = 0; UserId = $s.userId }
    }
    $usage[$devId][$upn].Count++
}

$report = [System.Collections.Generic.List[object]]::new()
foreach ($devId in $usage.Keys) {
    $device = $deviceMap[$devId]
    if (Test-PatternMatch -Value $device.deviceName -Patterns $ExcludedDevicePatterns) { continue }

    $users = $usage[$devId].GetEnumerator() | Sort-Object { $_.Value.Count } -Descending
    $top = $users | Select-Object -First 1
    $totalSignIns = ($users | ForEach-Object { $_.Value.Count } | Measure-Object -Sum).Sum
    $dominance = if ($totalSignIns -gt 0) { [math]::Round(($top.Value.Count / $totalSignIns) * 100, 1) } else { 0 }

    $primaryUpn = if ($device.userPrincipalName) { $device.userPrincipalName.ToLower() } else { '(none)' }
    $topUpn = $top.Key

    $isMismatch = ($topUpn -ne $primaryUpn) -and
                  ($top.Value.Count -ge $MinimumSignIns) -and
                  ($dominance -ge $DominancePercent)

    $report.Add([pscustomobject]@{
        DeviceName        = $device.deviceName
        IntuneDeviceId    = $device.id
        PrimaryUser       = $primaryUpn
        MostFrequentUser  = $topUpn
        MostFrequentUserId = $top.Value.UserId
        SignInCount       = $top.Value.Count
        DominancePct      = $dominance
        DistinctUsers     = $users.Count
        AllUsers          = ($users | ForEach-Object { "$($_.Key) ($($_.Value.Count))" }) -join '; '
        Mismatch          = $isMismatch
        LastSync          = $device.lastSyncDateTime
    })
}

# Devices with no sign-in data in the window (stale, offline, or logs aged out)
$seenIds = [System.Collections.Generic.HashSet[string]]::new([string[]]$usage.Keys)
foreach ($devId in $deviceMap.Keys) {
    if ($seenIds.Contains($devId)) { continue }
    $device = $deviceMap[$devId]
    if (Test-PatternMatch -Value $device.deviceName -Patterns $ExcludedDevicePatterns) { continue }
    $report.Add([pscustomobject]@{
        DeviceName        = $device.deviceName
        IntuneDeviceId    = $device.id
        PrimaryUser       = $device.userPrincipalName
        MostFrequentUser  = '(no sign-ins in window)'
        MostFrequentUserId = $null
        SignInCount       = 0
        DominancePct      = 0
        DistinctUsers     = 0
        AllUsers          = ''
        Mismatch          = $false
        LastSync          = $device.lastSyncDateTime
    })
}
#endregion Analyze

#region Report
$mismatches = $report | Where-Object Mismatch
$report | Sort-Object -Property @{Expression='Mismatch';Descending=$true}, DeviceName |
    Export-Csv -Path $ReportPath -NoTypeInformation

Write-Host ""
Write-Host ("Audit complete: {0} devices analyzed, {1} mismatches flagged." -f $report.Count, @($mismatches).Count) -ForegroundColor Green
Write-Host ("Report: {0}" -f $ReportPath)

if ($mismatches) {
    Write-Host ""
    $mismatches | Format-Table DeviceName, PrimaryUser, MostFrequentUser, SignInCount, DominancePct -AutoSize
}
#endregion Report

#region Fix
if ($Fix -and $mismatches) {
    Write-Host "Reassigning primary users on flagged devices..." -ForegroundColor Yellow
    $yesToAll = [bool]$Force
    $results = @{ Fixed = 0; Skipped = 0; Failed = 0 }
    foreach ($m in $mismatches) {
        if (-not $m.MostFrequentUserId) { continue }

        if (-not $yesToAll) {
            Write-Host ""
            Write-Host ("Device:  {0}" -f $m.DeviceName) -ForegroundColor Cyan
            Write-Host ("  Current primary user: {0}" -f $m.PrimaryUser)
            Write-Host ("  Suggested new user:   {0}  ({1} sign-ins, {2}% of activity)" -f $m.MostFrequentUser, $m.SignInCount, $m.DominancePct)
            Write-Host ("  All users seen:       {0}" -f $m.AllUsers)
            $answer = ''
            while ($answer -notin @('y','n','a','q')) {
                $answer = (Read-Host "  Change primary user? [Y]es / [N]o (skip) / [A]ll remaining / [Q]uit").Trim().ToLower()
            }
            if ($answer -eq 'n') {
                Write-Host ("  [SKIP] {0}" -f $m.DeviceName) -ForegroundColor DarkYellow
                $results.Skipped++
                continue
            }
            if ($answer -eq 'q') {
                Write-Host "  Stopping. Remaining devices left unchanged." -ForegroundColor DarkYellow
                break
            }
            if ($answer -eq 'a') { $yesToAll = $true }
        }

        if ($PSCmdlet.ShouldProcess($m.DeviceName, "Set primary user to $($m.MostFrequentUser)")) {
            try {
                $body = @{ '@odata.id' = "https://graph.microsoft.com/beta/users/$($m.MostFrequentUserId)" } | ConvertTo-Json
                Invoke-MgGraphRequest -Method POST `
                    -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$($m.IntuneDeviceId)')/users/`$ref" `
                    -Body $body -ContentType 'application/json'
                Write-Host ("  [OK] {0} -> {1}" -f $m.DeviceName, $m.MostFrequentUser) -ForegroundColor Green
                $results.Fixed++
            }
            catch {
                Write-Host ("  [FAIL] {0}: {1}" -f $m.DeviceName, $_.Exception.Message) -ForegroundColor Red
                $results.Failed++
            }
        }
    }
    Write-Host ""
    Write-Host ("Done. Fixed: {0}  Skipped: {1}  Failed: {2}" -f $results.Fixed, $results.Skipped, $results.Failed) -ForegroundColor Green
    Write-Host "Company Portal will reflect the new primary user after the next device check-in." -ForegroundColor Green
}
elseif ($Fix) {
    Write-Host "No mismatches to fix." -ForegroundColor Green
}
#endregion Fix
