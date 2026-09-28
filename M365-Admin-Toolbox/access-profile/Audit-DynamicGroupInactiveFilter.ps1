<#
.SYNOPSIS
    Audits all Entra ID dynamic groups and flags which ones do NOT exclude
    inactive/disabled users from their membership rule.

.DESCRIPTION
    THIS IS THE VENDOR-NEUTRAL VARIANT. Environment defaults are read from environment.psd1 beside this script - copy environment.example.psd1 and fill it in before first use. Every value there is a default; the equivalent parameter always wins.

    Pulls every dynamic-membership group in the tenant via Microsoft Graph,
    inspects each group's MembershipRule, and checks whether it already
    contains a clause that omits disabled/inactive accounts (i.e. something
    referencing "accountEnabled" - this applies to both user-based rules,
    e.g. user.accountEnabled, and device-based rules, e.g.
    device.accountEnabled, since Entra ID devices carry their own enabled
    state independent of the user who registered them).

    Groups that already have an accountEnabled clause are marked OK. Groups
    that don't are marked NEEDS ACCOUNTENABLED CLAUSE so you know which ones
    to fix.

    the organization REFERENCE EXAMPLES (from the most recent audit run):
      - "All Entra Company Users" is your known-good USER dynamic group:
        (user.mail -match "@contoso.com") and (user.accountEnabled -eq true)
        and (user.dirSyncEnabled -eq true) - matches this pattern when
        building new the organization user-based dynamic groups.
      - "All Entra Company Win PCs" is your known-good DEVICE dynamic
        group: it filters on device.accountEnabled (not user.accountEnabled),
        which is the correct clause for a device-based rule.
      - The most recent the organization audit flagged 7 groups, all Autopilot/app-
        assignment device groups (AP-All-Autopilot-Devices, AP-Dept-
        AppA, AP-Dept-AppB, AP-Dept-AppC, AP-Pilot,
        AP-Sales, Mobile Devices) plus "All Users" was OK. Before blindly
        running -Fix against the AP-* device groups, confirm with whoever
        owns Autopilot/Intune provisioning whether excluding disabled-device
        state is actually desired for deployment-scoped groups - a disabled
        device dropping out of an Autopilot group mid-provisioning could be
        disruptive if "disabled" ever gets set before provisioning completes.

    This script is READ-ONLY by default - it only reports, it does not
    modify any group's membership rule. Use -Fix to optionally patch
    flagged groups (with confirmation per group).

.PARAMETER Fix
    If specified, for each flagged group you'll be prompted whether to
    append '(user.accountEnabled -eq true)' to its membership rule via
    Update-MgGroup. Off by default - report-only is the safe default.

    NOTE: the appended clause is always 'user.accountEnabled', even for
    device-based rules. Review the proposed rule shown for each group before
    confirming - a device-only rule (e.g. AP-Dept-AppC above) needs
    'device.accountEnabled' instead, not 'user.accountEnabled'. Answer 'N'
    for any device group and add the correct clause manually via
    Update-MgGroup -MembershipRule if you want it fixed with the right
    property name.

.PARAMETER OutputPath
    Where to write the CSV report. Defaults to a fixed, shared location:
    a Reports\DynamicGroupAudits subfolder inside this script's own package folder
    (resolved via $PSScriptRoot, so the package is portable) - not a relative ".\..." path, so
    reports always land in the same findable spot no matter what directory
    PowerShell happens to be in when you run this.

.EXAMPLE
    .\Audit-DynamicGroupInactiveFilter.ps1

.EXAMPLE
    .\Audit-DynamicGroupInactiveFilter.ps1 -Fix

.NOTES
    Requires: Microsoft.Graph.Groups, Microsoft.Graph.Authentication
    Scopes:   Group.Read.All (report only), Group.ReadWrite.All (if -Fix)
    Version:  2026-07-10.1
#>

[CmdletBinding()]
param(
    [switch]$Fix,
    [string]$OutputFolder,
    [string]$OutputPath
)

# --- Portable path resolution ----------------------------------------------------------
# Resolve output locations against THIS SCRIPT'S OWN FOLDER so the whole package works
# unchanged from a flash drive, a UNC share, or a local disk. $PSScriptRoot is used
# deliberately instead of '.\' or $PWD, which resolve against whatever directory PowerShell
# happened to start in (C:\Windows\System32 when launched from a shortcut or the Run box).
$Script:PackageRoot = $PSScriptRoot
if (-not $Script:PackageRoot) { $Script:PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Script:PackageRoot) { $Script:PackageRoot = (Get-Location).Path }
if (-not $OutputFolder) { $OutputFolder = Join-Path $Script:PackageRoot 'Reports\DynamicGroupAudits' }
# ---------------------------------------------------------------------------------------


if (-not $OutputPath) {
    if (-not (Test-Path $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }
    $OutputPath = Join-Path $OutputFolder "DynamicGroup-InactiveFilterAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
}

Write-Host "=== Dynamic Group Inactive-User Filter Audit | script v2026-07-10.1 ===" -ForegroundColor Cyan
Write-Host "Report will be saved to: $OutputPath" -ForegroundColor DarkCyan

# --- Connect to Graph if needed ---
$requiredScopes = if ($Fix) { @("Group.ReadWrite.All") } else { @("Group.Read.All") }

if (-not (Get-MgContext)) {
    Write-Host "Connecting to Microsoft Graph (scopes: $($requiredScopes -join ', '))..." -ForegroundColor Yellow
    Connect-MgGraph -Scopes $requiredScopes | Out-Null
}
else {
    $currentScopes = (Get-MgContext).Scopes
    $missing = $requiredScopes | Where-Object { $_ -notin $currentScopes }
    if ($missing) {
        Write-Warning "Current Graph session is missing scope(s): $($missing -join ', '). Reconnecting."
        Disconnect-MgGraph | Out-Null
        Connect-MgGraph -Scopes $requiredScopes | Out-Null
    }
}

# --- Pull all dynamic-membership groups ---
Write-Host "Fetching all dynamic-membership groups..." -ForegroundColor Yellow

$dynamicGroups = Get-MgGroup -Filter "groupTypes/any(c:c eq 'DynamicMembership')" -All `
    -Property Id, DisplayName, MembershipRule, MembershipRuleProcessingState, MailNickname

if (-not $dynamicGroups -or $dynamicGroups.Count -eq 0) {
    Write-Host "No dynamic-membership groups found in this tenant." -ForegroundColor Yellow
    return
}

Write-Host "Found $($dynamicGroups.Count) dynamic group(s). Checking membership rules...`n" -ForegroundColor Yellow

$results = foreach ($grp in $dynamicGroups) {
    $rule = $grp.MembershipRule
    # Look for any reference to accountEnabled in the rule (covers -eq true / -eq "True" / accountEnabled -ne false etc.)
    $hasAccountEnabledClause = ($rule -match '(?i)accountEnabled')

    [pscustomobject]@{
        DisplayName    = $grp.DisplayName
        GroupId        = $grp.Id
        ProcessingState= $grp.MembershipRuleProcessingState
        Status         = if ($hasAccountEnabledClause) { "OK - has accountEnabled clause" } else { "NEEDS ACCOUNTENABLED CLAUSE" }
        MembershipRule = $rule
    }
}

# --- Console summary ---
$needsFix = $results | Where-Object { $_.Status -like "NEEDS*" }
$ok       = $results | Where-Object { $_.Status -like "OK*" }

Write-Host "Groups already excluding inactive users ($($ok.Count)):" -ForegroundColor Green
$ok | Select-Object DisplayName, ProcessingState | Format-Table -AutoSize | Out-String | Write-Host

Write-Host "Groups MISSING the inactive-user exclusion ($($needsFix.Count)):" -ForegroundColor Red
$needsFix | Select-Object DisplayName, ProcessingState, MembershipRule | Format-Table -AutoSize -Wrap | Out-String | Write-Host

# --- Export CSV ---
$results | Sort-Object Status, DisplayName | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Host "Full report exported to: $OutputPath" -ForegroundColor Cyan

# --- Optional fix pass ---
if ($Fix -and $needsFix.Count -gt 0) {
    Write-Host "`n--- Fix mode: reviewing $($needsFix.Count) flagged group(s) ---" -ForegroundColor Magenta

    foreach ($grp in $needsFix) {
        $newRule = "($($grp.MembershipRule)) and (user.accountEnabled -eq true)"
        Write-Host "`nGroup: $($grp.DisplayName)" -ForegroundColor Yellow
        Write-Host "  Current rule: $($grp.MembershipRule)"
        Write-Host "  Proposed rule: $newRule"
        $confirm = Read-Host "  Apply this change? (y/N)"
        if ($confirm -eq 'y') {
            try {
                Update-MgGroup -GroupId $grp.GroupId -MembershipRule $newRule -MembershipRuleProcessingState "On"
                Write-Host "  Updated." -ForegroundColor Green
            }
            catch {
                Write-Warning "  Failed to update $($grp.DisplayName): $($_.Exception.Message)"
            }
        }
        else {
            Write-Host "  Skipped." -ForegroundColor DarkYellow
        }
    }
}
elseif (-not $Fix -and $needsFix.Count -gt 0) {
    Write-Host "`nRun with -Fix to interactively patch the flagged group(s) (each change is confirmed individually before applying)." -ForegroundColor Yellow
}

Write-Host "`nDone." -ForegroundColor Cyan

