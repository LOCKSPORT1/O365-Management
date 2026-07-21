<#
.SYNOPSIS
Exports a Microsoft Teams inventory for a tenant to CSV, optionally including owners/members.
.DESCRIPTION
Connects to Microsoft Teams for the given tenant and exports one row per team, plus optional
additional rows per owner and/or member, to CSV. Useful for governance reviews and access audits.
.PARAMETER TenantName
Tenant name from config\tenants.json.
.PARAMETER OutputCsv
Path to write the exported Teams inventory CSV.
.PARAMETER IncludeOwners
Include one row per team owner in addition to the team-level row.
.PARAMETER IncludeMembers
Include one row per team member in addition to the team-level row.
.EXAMPLE
.\teams\Report-TeamsInventory.ps1 -TenantName Tenant-Example-NA
.EXAMPLE
.\teams\Report-TeamsInventory.ps1 -TenantName Tenant-Example-Cloud -IncludeOwners -IncludeMembers
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$OutputCsv = '.\reports\TeamsInventory.csv',
    [switch]$IncludeOwners,
    [switch]$IncludeMembers
)

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectTeams

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

try {
    $teams = Get-Team
    $rows = foreach ($team in $teams) {
        [pscustomobject]@{
            TenantName = $TenantName
            GroupId = $team.GroupId
            DisplayName = $team.DisplayName
            Visibility = $team.Visibility
            Archived = $team.Archived
            Description = $team.Description
            RecordType = 'Team'
            UserPrincipalName = ''
            Role = ''
        }
        if ($IncludeOwners) {
            foreach ($owner in (Get-TeamUser -GroupId $team.GroupId -Role Owner)) {
                [pscustomobject]@{
                    TenantName = $TenantName
                    GroupId = $team.GroupId
                    DisplayName = $team.DisplayName
                    Visibility = $team.Visibility
                    Archived = $team.Archived
                    Description = $team.Description
                    RecordType = 'Owner'
                    UserPrincipalName = $owner.User
                    Role = 'Owner'
                }
            }
        }
        if ($IncludeMembers) {
            foreach ($member in (Get-TeamUser -GroupId $team.GroupId -Role Member)) {
                [pscustomobject]@{
                    TenantName = $TenantName
                    GroupId = $team.GroupId
                    DisplayName = $team.DisplayName
                    Visibility = $team.Visibility
                    Archived = $team.Archived
                    Description = $team.Description
                    RecordType = 'Member'
                    UserPrincipalName = $member.User
                    Role = 'Member'
                }
            }
        }
    }
    $rows | Export-Csv -NoTypeInformation -Path $OutputCsv
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Teams inventory exported to $OutputCsv"
}
catch {
    Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "Teams inventory export failed: $($_.Exception.Message)"
    throw
}
