<#
.SYNOPSIS
    Applies a dynamic membership rule to an existing cloud-only (Intune-side)
    group, matching on the tag stamped by Sync-ADGroupTagToExtensionAttribute.ps1.
    One-time setup per group you want bridged - not something you run repeatedly.

.DESCRIPTION
    This is the cloud-side half of the bridge. Point it at a group that
    already exists (created directly in Entra/Intune, not synced from
    on-prem) and it sets:
        GroupTypes = DynamicMembership
        MembershipRule = (user.extensionAttributeN -contains ";TAG;")
        MembershipRuleProcessingState = On

.NOTES
    *** IMPORTANT - READ BEFORE RUNNING ***
    Converting an existing group to dynamic membership REPLACES its
    membership model. Any members currently added manually/statically will
    be dropped once dynamic processing takes over - the group becomes
    dynamic-only going forward. If the group currently has manual members
    you need to keep, either fold their AD accounts into the mapped local
    group first (so they get re-added via the tag) or capture the current
    member list before running this (the script does that for you below
    and prints it as a safety net).

    Dynamic group membership requires at least one Entra ID P1 license in
    the tenant. Security groups (not just M365 Groups) support dynamic
    membership - that's the type Intune-assigned groups typically use.

    Self-connects to Graph automatically if not already connected
    (see -AuthMode param; defaults to Interactive).
    Requires Graph scope Group.ReadWrite.All.

.PARAMETER GroupName
    Display name of the existing cloud-only group to convert to dynamic
    membership. Must resolve to exactly one group.

.PARAMETER Tag
    The tag value to match, e.g. "APP1TAG". Must correspond to a value
    from GroupTagMap in Sync-ADGroupTagToExtensionAttribute.ps1.

.PARAMETER Confirmed
    Required switch to actually apply the change. Without it, the script
    only previews the group's current state and member snapshot.

.PARAMETER AuthMode
    One of Interactive, AppSecret, Certificate. Defaults to Interactive.
    See Connect-M365Services.ps1 for details.

.EXAMPLE
    .\Set-EntraDynamicGroupRule.ps1 -GroupName "Intune-App1-Admins" -Tag "APP1TAG"
    Preview only - prints current group state and member snapshot, makes no changes.

.EXAMPLE
    .\Set-EntraDynamicGroupRule.ps1 -GroupName "Intune-App1-Admins" -Tag "APP1TAG" -Confirmed
    Applies the dynamic membership rule after you've reviewed the preview output.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$GroupName,
    [Parameter(Mandatory)][string]$Tag,
    [switch]$Confirmed,   # explicit gate - this is a one-way membership model change

    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$Config = @{
    # Which extensionAttribute (1-15) carries the tag stamped by
    # Sync-ADGroupTagToExtensionAttribute.ps1. MUST match that script's
    # TargetExtensionAttribute value or the dynamic rule will never match anyone.
    ExtensionAttribute = "extensionAttribute15"

    # Wraps each tag in the rule's -contains match, e.g. ";APP1TAG;". MUST match
    # the TagDelimiter used in Sync-ADGroupTagToExtensionAttribute.ps1.
    TagDelimiter        = ";"
}

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

try {
    $groups = @(Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction Stop)
}
catch {
    Write-Error "Failed to query Microsoft Graph for group '$GroupName': $_"
    return
}

if ($groups.Count -eq 0) {
    Write-Error "Group '$GroupName' not found."
    return
}
if ($groups.Count -gt 1) {
    Write-Error "Multiple groups named '$GroupName' were found (Ids: $($groups.Id -join ', ')). Re-run against a unique group Id to avoid converting the wrong group."
    return
}
$group = $groups[0]

Write-Host "Target group: $($group.DisplayName) (Id: $($group.Id))" -ForegroundColor Cyan
Write-Host "Current GroupTypes: $($group.GroupTypes -join ', ')"
Write-Host "Current MembershipRule: $($group.MembershipRule)"

# Safety net: snapshot current members before converting, in case anything needs to be re-added manually to the source AD group
try {
    $currentMembers = Get-MgGroupMember -GroupId $group.Id -All -ErrorAction Stop
}
catch {
    Write-Error "Failed to retrieve current members for group '$GroupName': $_"
    return
}

if ($currentMembers) {
    Write-Host "`nCurrent members (WILL BE DROPPED once dynamic rule takes effect - re-add via the mapped local AD group if they should stay):" -ForegroundColor Yellow
    $currentMembers | ForEach-Object { Write-Host "  $($_.AdditionalProperties.displayName) ($($_.AdditionalProperties.userPrincipalName))" }
}
else {
    Write-Host "`nNo current members - safe to convert." -ForegroundColor Green
}

if (-not $Confirmed) {
    Write-Host "`nThis is a one-way membership model change. Re-run with -Confirmed once you've reviewed the member list above." -ForegroundColor Red
    return
}

$rule = "(user.$($Config.ExtensionAttribute) -contains `"$($Config.TagDelimiter)$Tag$($Config.TagDelimiter)`")"
Write-Host "`nApplying rule: $rule" -ForegroundColor Cyan

if ($PSCmdlet.ShouldProcess($GroupName, "Convert to dynamic membership with rule: $rule")) {
    try {
        Update-MgGroup -GroupId $group.Id `
            -GroupTypes @("DynamicMembership") `
            -MembershipRule $rule `
            -MembershipRuleProcessingState "On" `
            -ErrorAction Stop

        Write-Host "[OK] Group converted to dynamic membership." -ForegroundColor Green
        Write-Host "Initial rule processing can take anywhere from a few minutes to a couple hours to fully evaluate against all users the first time - re-check membership later rather than assuming it's instant."
    }
    catch {
        Write-Error "Failed to update group '$GroupName' with the new dynamic membership rule: $_"
    }
}
