<#
.SYNOPSIS
    Finds M365 Groups, Teams, and Distribution Groups with zero owners -
    a common governance gap where a group outlives the person who
    created it and nobody can manage membership, approve access, or
    even know it's theirs to maintain.

.DESCRIPTION
    Ownerless groups are a recurring audit finding: when the creator
    leaves and offboarding didn't explicitly reassign ownership, the
    group is orphaned but keeps working (existing members retain access)
    with nobody accountable for it. This report surfaces them so
    ownership can be reassigned proactively instead of discovered during
    a security review.

.PARAMETER ExportPath
    Path to write the CSV report to.

.PARAMETER AuthMode
    Interactive, AppSecret, or Certificate - passed through to
    Assert-M365Connection. Defaults to Interactive.

.EXAMPLE
    .\Get-OwnerlessGroupsReport.ps1

.EXAMPLE
    .\Get-OwnerlessGroupsReport.ps1 -ExportPath "C:\Reports\OwnerlessGroups.csv" -AuthMode Certificate

.NOTES
    Requires Graph scope Group.Read.All.
#>

[CmdletBinding()]
param(
    # ============================================================
    # CONFIGURATION - adjust these values for your environment
    # ============================================================
    # Output path for the CSV report.
    [string]$ExportPath = ".\OwnerlessGroups_$(Get-Date -Format 'yyyyMMdd').csv",

    # Auth mode passed through to Assert-M365Connection (Interactive/AppSecret/Certificate).
    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

Write-Host "Pulling all groups and checking ownership..." -ForegroundColor Cyan
try {
    $groups = Get-MgGroup -All -Property Id,DisplayName,GroupTypes,Mail,CreatedDateTime,SecurityEnabled
}
catch {
    Write-Error "Failed to retrieve groups from Graph: $($_.Exception.Message)"
    return
}

$report = foreach ($g in $groups) {
    try {
        $owners = Get-MgGroupOwner -GroupId $g.Id -All
    }
    catch {
        Write-Warning "Failed to retrieve owners for group '$($g.DisplayName)': $($_.Exception.Message)"
        continue
    }

    if ($owners.Count -eq 0) {
        try {
            $memberCount = (Get-MgGroupMember -GroupId $g.Id -All).Count
        }
        catch {
            Write-Warning "Failed to retrieve member count for group '$($g.DisplayName)': $($_.Exception.Message)"
            $memberCount = $null
        }
        $groupType = if ($g.GroupTypes -contains "Unified") { "Microsoft 365 Group / Team" }
                     elseif ($g.SecurityEnabled) { "Security Group" }
                     else { "Distribution Group" }

        [PSCustomObject]@{
            DisplayName  = $g.DisplayName
            GroupType    = $groupType
            Mail         = $g.Mail
            MemberCount  = $memberCount
            CreatedDate  = $g.CreatedDateTime
            GroupId      = $g.Id
        }
    }
}

$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Exported $($report.Count) ownerless group(s) to $ExportPath" -ForegroundColor Green

if ($report) {
    Write-Host "`n=== Ownerless groups needing an assigned owner ===" -ForegroundColor Yellow
    $report | Sort-Object MemberCount -Descending | Format-Table DisplayName, GroupType, MemberCount, CreatedDate -AutoSize
}
else {
    Write-Host "`nNo ownerless groups found." -ForegroundColor Green
}
