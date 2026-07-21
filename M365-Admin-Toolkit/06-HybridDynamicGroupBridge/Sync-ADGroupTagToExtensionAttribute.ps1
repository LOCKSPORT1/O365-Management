<#
.SYNOPSIS
    Stamps a delimited "tag" string onto an AD user's extensionAttribute
    based on which local AD security groups they belong to - the on-prem
    half of bridging local AD group membership into Entra ID dynamic
    groups (which cannot evaluate memberOf directly).

.DESCRIPTION
    Entra ID dynamic membership rules have no supported way to say
    "member of AD/Entra group X." The standard workaround is:
      1. THIS script: local AD group membership -> tag written to an
         extensionAttribute on the user object.
      2. Entra Connect syncs that attribute up automatically (extensionAttribute
         1-15 sync by default - no schema extension work needed).
      3. The cloud-side dynamic group's membership rule matches on that
         tag (see Set-EntraDynamicGroupRule.ps1 in this folder).

    Once wired up, the workflow becomes: add a user to the mapped local AD
    group -> next run of this script (scheduled task) stamps the tag ->
    next Entra Connect sync cycle pushes it up -> the cloud dynamic group
    picks the user up on its own, no manual add required.

    Handles removals too: if a user is taken out of the local group, their
    tag is recalculated and the group's tag is dropped from their
    extensionAttribute on the next run - which removes them from the
    dynamic group on the next sync.

.PARAMETER TriggerEntraConnectSync
    After a successful (non-WhatIf) run that made at least one change,
    remotely triggers a delta sync on the Entra Connect server named in
    $Config.EntraConnectServer via Invoke-Command (requires WinRM access
    and rights to run Start-ADSyncSyncCycle there).

.PARAMETER WhatIfOnly
    Preview every add/change/clear that would happen, without writing
    anything to AD.

.EXAMPLE
    .\Sync-ADGroupTagToExtensionAttribute.ps1 -WhatIfOnly
    Preview what would change with no writes.

.EXAMPLE
    .\Sync-ADGroupTagToExtensionAttribute.ps1 -TriggerEntraConnectSync
    Real run; kicks a delta sync afterward if anything changed.

.NOTES
    Run this as a scheduled task on a domain-joined host (typically the DC
    itself, same pattern as your existing department-field automation
    script). Requires the ActiveDirectory RSAT module to be installed on
    whatever host runs this. Designed to be idempotent - safe to run as
    often as you like; it only writes to AD when a user's computed tag
    value actually changes.
#>

[CmdletBinding()]
param(
    [switch]$TriggerEntraConnectSync,
    [switch]$WhatIfOnly   # preview changes without writing to AD
)

#region Configuration - EDIT THESE VARIABLES
$Config = @{
    ADServer                = "dc01.yourdomain.local"
    SearchBase              = "OU=Users,DC=yourdomain,DC=local"

    # Which extensionAttribute to use as the tag carrier. Pick one that
    # nothing else in your environment is already using (check first with
    # Get-ADUser -Filter * -Properties extensionAttribute1-15 on a sample).
    TargetExtensionAttribute = "extensionAttribute15"
    TagDelimiter             = ";"    # wraps each tag so partial-name matches can't collide, e.g. ";APP1TAG;"

    # Map: local AD security group name -> tag stamped for members of that group.
    # Add one entry per cloud-side group you want to bridge.
    GroupTagMap = @{
        "SG-Local-Bridge-App1Admins" = "APP1TAG"
        "SG-Local-Bridge-App2Users"   = "APP2TAG"
        "SG-Local-Bridge-App3Users"   = "APP3TAG"
    }

    # Entra Connect server + sync command, used only if -TriggerEntraConnectSync is passed
    EntraConnectServer      = "aadconnect01.yourdomain.local"
    EntraConnectSyncCommand = "Start-ADSyncSyncCycle -PolicyType Delta"

    # Milliseconds to pause between each Set-ADUser write, to avoid hammering
    # the DC when updating a large number of users in one run. Set to 0 to disable.
    ThrottleDelayMs         = 100
}
#endregion

try {
    Import-Module ActiveDirectory -ErrorAction Stop
}
catch {
    Write-Error "ActiveDirectory module is not available on this host. This script must run from a domain-joined host with RSAT AD tools installed. $_"
    return
}

Write-Host "Building membership map from $($Config.GroupTagMap.Count) local group(s)..." -ForegroundColor Cyan

# userDN -> [HashSet of tags]
$userTags = @{}

foreach ($groupName in $Config.GroupTagMap.Keys) {
    $tag = $Config.GroupTagMap[$groupName]
    try {
        $members = Get-ADGroupMember -Identity $groupName -Server $Config.ADServer -Recursive -ErrorAction Stop |
            Where-Object { $_.objectClass -eq 'user' }
    }
    catch {
        Write-Warning "Group '$groupName' not found or unreadable - skipping. $_"
        continue
    }

    foreach ($m in $members) {
        if (-not $userTags.ContainsKey($m.DistinguishedName)) {
            $userTags[$m.DistinguishedName] = New-Object System.Collections.Generic.HashSet[string]
        }
        [void]$userTags[$m.DistinguishedName].Add($tag)
    }
    Write-Host "  $groupName -> tag '$tag' -> $($members.Count) member(s)" -ForegroundColor Gray
}

# Pull every user who EITHER matched a mapped group above OR already has a value
# in the target attribute, so we correctly clear tags for users who were removed
# from a mapped group since the last run.
Write-Host "Pulling current attribute state from AD (SearchBase: $($Config.SearchBase))..." -ForegroundColor Cyan
try {
    $allCandidates = Get-ADUser -Filter * -SearchBase $Config.SearchBase -Server $Config.ADServer `
        -Properties $Config.TargetExtensionAttribute, DistinguishedName -ErrorAction Stop |
        Where-Object { $userTags.ContainsKey($_.DistinguishedName) -or $_.$($Config.TargetExtensionAttribute) }
}
catch {
    Write-Error "Failed to query AD users under SearchBase '$($Config.SearchBase)' on server '$($Config.ADServer)': $_"
    return
}

$changed = 0
$unchanged = 0
$cleared = 0

foreach ($user in $allCandidates) {
    $tagSet = $userTags[$user.DistinguishedName]
    $desiredValue = if ($tagSet -and $tagSet.Count -gt 0) {
        $Config.TagDelimiter + (($tagSet | Sort-Object) -join $Config.TagDelimiter) + $Config.TagDelimiter
    } else {
        $null
    }

    $currentValue = $user.$($Config.TargetExtensionAttribute)

    if ($currentValue -eq $desiredValue) {
        $unchanged++
        continue
    }

    if ($WhatIfOnly) {
        Write-Host "[WHATIF] $($user.SamAccountName): '$currentValue' -> '$desiredValue'" -ForegroundColor Yellow
        continue
    }

    try {
        if ($desiredValue) {
            Set-ADUser -Identity $user.DistinguishedName -Replace @{ $Config.TargetExtensionAttribute = $desiredValue } -Server $Config.ADServer
            Write-Host "[OK] $($user.SamAccountName): tagged '$desiredValue'" -ForegroundColor Green
        } else {
            Set-ADUser -Identity $user.DistinguishedName -Clear $Config.TargetExtensionAttribute -Server $Config.ADServer
            Write-Host "[OK] $($user.SamAccountName): cleared (no mapped group membership)" -ForegroundColor Yellow
            $cleared++
        }
        $changed++

        if ($Config.ThrottleDelayMs -gt 0) {
            Start-Sleep -Milliseconds $Config.ThrottleDelayMs
        }
    }
    catch {
        Write-Warning "Failed to update $($user.SamAccountName): $_"
    }
}

Write-Host "`nSummary: $changed changed ($cleared cleared), $unchanged already correct." -ForegroundColor Cyan

if ($TriggerEntraConnectSync -and -not $WhatIfOnly -and $changed -gt 0) {
    Write-Host "Triggering Entra Connect delta sync on $($Config.EntraConnectServer)..." -ForegroundColor Cyan
    Invoke-Command -ComputerName $Config.EntraConnectServer -ScriptBlock {
        param($cmd) Invoke-Expression $cmd
    } -ArgumentList $Config.EntraConnectSyncCommand
}
elseif ($changed -eq 0) {
    Write-Host "No changes - skipping sync trigger." -ForegroundColor Gray
}
