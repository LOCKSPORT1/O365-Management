<#
.SYNOPSIS
    Audits all Entra ID dynamic-membership groups and flags user-scoped groups
    that don't exclude disabled/inactive accounts from membership.

.DESCRIPTION
    Retrieves every dynamic-membership group for the tenant via Microsoft Graph
    and inspects each group's MembershipRule. Rules are classified as:

      - USER-SCOPED, OK              -> rule references a user attribute and
                                         already contains an accountEnabled clause
      - USER-SCOPED, NEEDS FIX       -> rule references a user attribute but has
                                         no accountEnabled clause (disabled/inactive
                                         accounts can still match and be added)
      - DEVICE-SCOPED (not checked)  -> rule targets device.* attributes (e.g.
                                         Autopilot/Intune enrollment groups). The
                                         user.accountEnabled concept doesn't apply
                                         to these, so they are reported separately
                                         and never flagged as needing the fix.

    This distinction matters: a naive check that flags every dynamic group missing
    the string "accountEnabled" will produce false positives against any
    device-scoped rule, since those correctly target device attributes and have
    nothing to do with inactive user accounts. Only user-scoped rules are
    evaluated against the accountEnabled requirement.

    Read-only by default. Use -Fix to interactively patch flagged user-scoped
    groups (confirmed one at a time before any change is applied).

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json.

.PARAMETER OutputCsv
    Path to the CSV report. Defaults to .\reports\DynamicGroupInactiveFilter.csv.

.PARAMETER Fix
    If specified, prompts per flagged user-scoped group to append
    '(user.accountEnabled -eq true)' to its membership rule via Update-MgGroup.
    Off by default.

.EXAMPLE
    .\Report-DynamicGroupInactiveFilter.ps1 -TenantName 'Tenant-Example-NA'

.EXAMPLE
    .\Report-DynamicGroupInactiveFilter.ps1 -TenantName 'Tenant-Example-NA' -Fix

.NOTES
    Part of the M365 Admin Toolbox reporting scripts (entra\). Run this after
    creating any new dynamic user group, and periodically (e.g. quarterly) as a
    hygiene check alongside license/seat reviews.
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$OutputCsv = '.\reports\DynamicGroupInactiveFilter.csv',
    [switch]$Fix
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Number of retry attempts for throttle-safe Graph calls
$MaxRetryAttempts = 5
# Base delay (seconds) between retry attempts (doubles each attempt, capped at 60s)
$RetryBaseDelaySeconds = 5

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectGraph

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

Invoke-ToolboxSafely -TenantName $TenantName -Operation 'Report-DynamicGroupInactiveFilter' -Rethrow -ScriptBlock {

    $groups = Invoke-WithRetry -TenantName $TenantName -Operation 'Get-MgGroup (dynamic)' -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
        Get-MgGroup -Filter "groupTypes/any(c:c eq 'DynamicMembership')" -All `
            -Property Id, DisplayName, MembershipRule, MembershipRuleProcessingState
    }

    $rows = foreach ($grp in $groups) {
        $rule = [string]$grp.MembershipRule
        $isDeviceScoped = $rule -match '(?i)\bdevice\.'
        $hasAccountEnabled = $rule -match '(?i)accountEnabled'

        $status = if ($isDeviceScoped) {
            'DEVICE-SCOPED (not checked)'
        } elseif ($hasAccountEnabled) {
            'USER-SCOPED, OK'
        } else {
            'USER-SCOPED, NEEDS FIX'
        }

        [pscustomobject]@{
            TenantName      = $TenantName
            DisplayName     = $grp.DisplayName
            GroupId         = $grp.Id
            ProcessingState = $grp.MembershipRuleProcessingState
            Status          = $status
            MembershipRule  = $rule
        }
    }

    $rows | Sort-Object Status, DisplayName | Export-Csv -NoTypeInformation -Path $OutputCsv

    $needsFix = $rows | Where-Object { $_.Status -eq 'USER-SCOPED, NEEDS FIX' }
    $ok       = $rows | Where-Object { $_.Status -eq 'USER-SCOPED, OK' }
    $devices  = $rows | Where-Object { $_.Status -eq 'DEVICE-SCOPED (not checked)' }

    Write-ToolboxLog -TenantName $TenantName -Level 'INFO' -Message "Dynamic groups: $($ok.Count) user-scoped OK, $($needsFix.Count) user-scoped need fix, $($devices.Count) device-scoped (not checked)."
    if ($needsFix.Count -gt 0) {
        Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "Needs fix: $(($needsFix.DisplayName) -join ', ')"
    }
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Dynamic group inactive-filter report exported to $OutputCsv"

    if ($Fix -and $needsFix.Count -gt 0) {
        foreach ($grp in $needsFix) {
            $newRule = "($($grp.MembershipRule)) and (user.accountEnabled -eq true)"
            Write-Host "`nGroup: $($grp.DisplayName)" -ForegroundColor Yellow
            Write-Host "  Current rule:  $($grp.MembershipRule)"
            Write-Host "  Proposed rule: $newRule"
            $confirm = Read-Host '  Apply this change? (y/N)'
            if ($confirm -eq 'y') {
                Invoke-WithRetry -TenantName $TenantName -Operation "Update-MgGroup ($($grp.DisplayName))" -MaxAttempts $MaxRetryAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
                    Update-MgGroup -GroupId $grp.GroupId -MembershipRule $newRule -MembershipRuleProcessingState 'On'
                }
                Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Updated membership rule for '$($grp.DisplayName)'."
            } else {
                Write-ToolboxLog -TenantName $TenantName -Level 'INFO' -Message "Skipped '$($grp.DisplayName)' (no change applied)."
            }
        }
    } elseif (-not $Fix -and $needsFix.Count -gt 0) {
        Write-Host "`nRun with -Fix to interactively patch the flagged group(s) (each change confirmed individually)." -ForegroundColor Yellow
    }
}
