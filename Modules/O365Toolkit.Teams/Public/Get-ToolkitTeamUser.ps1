# Modules/O365Toolkit.Teams/Public/Get-ToolkitTeamUser.ps1
<#
.SYNOPSIS
    Retrieves members and owners of a specified Microsoft Team.
.DESCRIPTION
    Queries Microsoft Graph for members and owners assigned to a specific Microsoft Team / Group ID.
    Supports filtering by role (owner, member, guest) and server-side paging.
.PARAMETER TeamId
    The unique GUID of the Microsoft Team.
.PARAMETER Role
    Optional filter for user roles: 'owner', 'member', or 'guest'.
.PARAMETER Top
    The maximum number of items to return per page.
.PARAMETER AllPages
    Retrieves all pages of results automatically via @odata.nextLink.
.PARAMETER Config
    Optional configuration hashtable containing environment settings.
.OUTPUTS
    [pscustomobject]
.EXAMPLE
    Get-ToolkitTeamUser -TeamId '00000000-0000-0000-0000-000000000000'
.EXAMPLE
    Get-ToolkitTeamUser -TeamId '00000000-0000-0000-0000-000000000000' -Role 'owner'
.NOTES
    Required Microsoft Graph Scopes:
      - TeamMember.Read.All or GroupMember.Read.All or Directory.Read.All
#>
function Get-ToolkitTeamUser {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TeamId,

        [Parameter()]
        [ValidateSet('owner', 'member', 'guest')]
        [string]$Role,

        [Parameter()]
        [ValidateRange(1, 999)]
        [int]$Top,

        [Parameter()]
        [switch]$AllPages,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Config = @{ Environment = 'Global' }
    )

    # ---------------------------------------------------------------------------
    # CHANGE: 2026-08-18 - Initial creation of Get-ToolkitTeamUser for
    # O365Toolkit.Teams adhering to Graph API v1.0 standards and locked lexicon.
    # Module: O365Toolkit.Teams
    # Track: NEUTRAL
    # ---------------------------------------------------------------------------

    Assert-ToolkitGraphConnection

    if (-not $Config) {
        $Config = @{ Environment = 'Global' }
    }

    $relativeUri = "v1.0/teams/$TeamId/members"
    $queryParams = [System.Collections.Generic.List[string]]::new()

    if ($PSBoundParameters.ContainsKey('Top') -and $Top -gt 0) {
        $queryParams.Add("`$top=$Top")
    }

    if ($queryParams.Count -gt 0) {
        $relativeUri += '?' + ($queryParams -join '&')
    }

    $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config

    $requestParams = @{
        Uri      = $requestUri
        Method   = 'GET'
        Config   = $Config
        AllPages = $AllPages.IsPresent
    }

    $members = Invoke-ToolkitGraphRequest @requestParams

    foreach ($m in $members) {
        $roles = @($m.roles)
        $isOwner = $roles -contains 'owner'
        $isGuest = $m.userPrincipalName -like '*#EXT#*' -or ($m.'@odata.type' -like '*guest*')
        $assignedRole = if ($isOwner) { 'owner' } elseif ($isGuest) { 'guest' } else { 'member' }

        if ($Role -and $assignedRole -ne $Role) {
            continue
        }

        [PSCustomObject]@{
            TeamId            = $TeamId
            MembershipId      = $m.id
            UserId            = $m.userId
            DisplayName       = $m.displayName
            UserPrincipalName = $m.userPrincipalName
            Email             = $m.email
            Role              = $assignedRole
            Roles             = $roles
            VisibleHistoryStartDateTime = $m.visibleHistoryStartDateTime
        }
    }
}