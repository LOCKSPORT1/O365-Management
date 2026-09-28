#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only. Reports which Entra Connect sync rules flow a given attribute, and classifies
    whether any of them can overwrite a cloud-set value.

.DESCRIPTION
    RUN THIS ON THE ENTRA CONNECT SERVER. It cannot be run remotely.

    The ADSync management cmdlets (Get-ADSyncRule, Get-ADSyncConnector) talk to the sync
    service over a WCF named-pipe endpoint at net.pipe://localhost/ADSyncManagement, and
    named-pipe WCF endpoints are not reachable through PowerShell remoting. Invoked via
    Invoke-Command they fail with:

        There was no endpoint listening at net.pipe://localhost/ADSyncManagement

    which reads like the service is down. It isn't - the scheduler cmdlets
    (Start-ADSyncSyncCycle, Get-ADSyncScheduler) use a different channel and work remotely
    just fine, which makes the failure look like a permissions problem when it is a transport
    one. Hence: run this locally.

    WHY THIS CHECK EXISTS
    On a hybrid-synced user, Entra Connect is authoritative for any attribute its rules flow.
    Set such an attribute in the cloud and the next sync cycle overwrites it with whatever AD
    holds - usually nothing. The write succeeds, dependent operations a few seconds later
    succeed, and then the value silently empties. Nothing on the Entra side reports it.

    Merely appearing in a sync rule proves nothing, though, so this classifies by shape:

      Inbound from the AD connector    RISK. AD is the source of truth for the metaverse
                                       value, so an empty AD attribute blanks the cloud one.
      Inbound from the AAD connector   Benign. Imports the EXISTING cloud value into the
                                       metaverse. Cannot originate a blank.
      Outbound to AAD, guarded by
      IgnoreThisFlow / IsNullOrEmpty   Benign. The rule explicitly declines to write when the
                                       metaverse value is empty - the guard against clobbering.
      Outbound to AAD, unguarded       RISK. Pushes whatever the metaverse holds, incl. nothing.

.PARAMETER AttributeName
    Metaverse attribute to check. Defaults to usageLocation. Any attribute is valid - the same
    trap applies to all of them.

.EXAMPLE
    .\Test-UsageLocationSyncRules.ps1
    Checks usageLocation.

.EXAMPLE
    .\Test-UsageLocationSyncRules.ps1 -AttributeName department
    Same analysis for a different attribute.

.NOTES
    Example from one hybrid tenant: only two enabled rules touch usageLocation -
    'In from AAD - User Join' (inbound from AAD) and 'Out to AAD - User Join' (outbound,
    guarded by IgnoreThisFlow). Both benign, no rule sources it from the on-premises
    connector, so usageLocation is cloud-authoritative and safe to set via Graph.
#>
[CmdletBinding()]
param(
    [string]$AttributeName = 'usageLocation'
)

$ErrorActionPreference = 'Stop'
$Script:ScriptVersion = "2026-08-06.1 (initial - local-only; remoting cannot reach the ADSync named pipe)"

Write-Host "`nTest-UsageLocationSyncRules  $Script:ScriptVersion" -ForegroundColor DarkGray
Write-Host "Read-only. Attribute: $AttributeName`n" -ForegroundColor DarkGray

try {
    Import-Module ADSync -ErrorAction Stop
}
catch {
    Write-Host "Couldn't load the ADSync module: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "This script only works ON the Entra Connect server." -ForegroundColor Red
    return
}

# Connector names distinguish AD from AAD. Optional - rule-name matching is a good fallback
# for out-of-box rules.
$connectorNames = @{}
try {
    foreach ($c in (Get-ADSyncConnector -ErrorAction Stop)) {
        $connectorNames[[string]$c.Identifier] = $c.Name
    }
}
catch {
    Write-Warning "Couldn't resolve connector names ($($_.Exception.Message)) - falling back to rule-name matching."
}

try {
    $allRules = @(Get-ADSyncRule -ErrorAction Stop)
}
catch {
    Write-Host "Get-ADSyncRule failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Message -match 'net\.pipe://localhost/ADSyncManagement') {
        Write-Host ""
        Write-Host "That named-pipe error means this is running remotely, or the sync service" -ForegroundColor Yellow
        Write-Host "is stopped. Run it in a local session ON the Entra Connect server." -ForegroundColor Yellow
    }
    return
}

$hits = New-Object System.Collections.Generic.List[Object]
foreach ($rule in $allRules) {
    foreach ($m in @($rule.AttributeFlowMappings)) {
        if ($m.Destination -eq $AttributeName) {
            $cid = [string]$rule.Connector
            $hits.Add([PSCustomObject]@{
                Rule       = $rule.Name
                Direction  = [string]$rule.Direction
                Precedence = $rule.Precedence
                Disabled   = [bool]$rule.Disabled
                Connector  = $(if ($connectorNames.ContainsKey($cid)) { $connectorNames[$cid] } else { "(unresolved: $cid)" })
                Source     = (@($m.Source) -join ', ')
                Expression = [string]$m.Expression
            })
        }
    }
}

$active = @($hits | Where-Object { -not $_.Disabled })
$disabledCount = @($hits).Count - $active.Count

Write-Host "Rules touching '$AttributeName': $(@($hits).Count) total, $($active.Count) enabled" -ForegroundColor Cyan
if ($disabledCount -gt 0) {
    Write-Host "  ($disabledCount disabled rule(s) ignored)" -ForegroundColor DarkGray
}
Write-Host ""

if ($active.Count -eq 0) {
    Write-Host "No enabled sync rule touches '$AttributeName'." -ForegroundColor Green
    Write-Host "The cloud value is authoritative and will not be overwritten by a sync." -ForegroundColor Green
    return
}

$risks = New-Object System.Collections.Generic.List[Object]
foreach ($o in $active) {
    $looksAad = ($o.Rule -match 'AAD|Entra') -or ($o.Connector -match 'AAD|onmicrosoft\.com')
    $guarded  = $o.Expression -match 'IgnoreThisFlow|IsNullOrEmpty'

    if ($o.Direction -eq 'Inbound' -and $looksAad) {
        $verdict = 'BENIGN'
        $why = "Inbound from the AAD connector - imports the existing cloud value into the metaverse. Cannot originate a blank."
    }
    elseif ($o.Direction -eq 'Inbound') {
        $verdict = 'RISK'
        $why = "Inbound from the on-premises connector '$($o.Connector)', sourced from '$($o.Source)'. AD is authoritative, so an empty AD attribute blanks the cloud value on each sync."
    }
    elseif ($guarded) {
        $verdict = 'BENIGN'
        $why = "Outbound to AAD but guarded by IgnoreThisFlow/IsNullOrEmpty - declines to write when the metaverse value is empty, so it cannot clobber a cloud-set value."
    }
    else {
        $verdict = 'RISK'
        $why = "Outbound to AAD with no IgnoreThisFlow/IsNullOrEmpty guard - pushes whatever the metaverse holds, including nothing."
    }

    $colour = if ($verdict -eq 'RISK') { 'Yellow' } else { 'DarkGray' }
    Write-Host "[$verdict] $($o.Rule)   [$($o.Direction), precedence $($o.Precedence)]" -ForegroundColor $colour
    Write-Host "         connector : $($o.Connector)" -ForegroundColor DarkGray
    if ($o.Source)     { Write-Host "         source    : $($o.Source)" -ForegroundColor DarkGray }
    if ($o.Expression) { Write-Host "         expression: $($o.Expression)" -ForegroundColor DarkGray }
    Write-Host "         $why" -ForegroundColor $colour
    Write-Host ""

    if ($verdict -eq 'RISK') { $risks.Add($o) }
}

Write-Host ("-" * 70)
if ($risks.Count -eq 0) {
    Write-Host "VERDICT: no rule can blank a cloud-set '$AttributeName'." -ForegroundColor Green
    Write-Host "It is effectively cloud-authoritative here, so setting it via Graph is correct" -ForegroundColor Green
    Write-Host "and durable. If the value still goes missing, the cause is not Entra Connect -" -ForegroundColor Green
    Write-Host "check the relevant rows in the provisioning report instead." -ForegroundColor Green
}
else {
    Write-Host "VERDICT: $($risks.Count) rule(s) CAN blank a cloud-set '$AttributeName'." -ForegroundColor Yellow
    Write-Host "Fix at the source - populate the AD attribute named above - or disable that" -ForegroundColor Yellow
    Write-Host "attribute mapping if the cloud should own the value. Note that anything already" -ForegroundColor Yellow
    Write-Host "derived from the value (licenses, for instance) is NOT rolled back when it" -ForegroundColor Yellow
    Write-Host "empties, which is why dependent objects can look correct while the attribute" -ForegroundColor Yellow
    Write-Host "itself looks unset." -ForegroundColor Yellow
}
Write-Host ("-" * 70)
