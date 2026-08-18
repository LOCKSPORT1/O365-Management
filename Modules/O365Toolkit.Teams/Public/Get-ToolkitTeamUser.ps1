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

    Assert-ToolkitGraphConnection
    if (-not $Config) { $Config = @{ Environment = 'Global' } }

    $relativeUri = "v1.0/teams/$TeamId/members"
    $queryParams = [System.Collections.Generic.List[string]]::new()

    if ($PSBoundParameters.ContainsKey('Top') -and $Top -gt 0) {
        $queryParams.Add("`$top=$Top")
    }

    if ($queryParams.Count -gt 0) {
        $relativeUri += '?' + ($queryParams -join '&')
    }

    $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config
    $members = Invoke-ToolkitGraphRequest -Uri $requestUri -Method 'GET' -Config $Config -AllPages:$AllPages.IsPresent

    foreach ($m in $members) {
        $roles = @()
        if ($m.PSObject.Properties['roles']) { $roles = @($m.roles) }
        $upn = if ($m.PSObject.Properties['userPrincipalName']) { $m.userPrincipalName } else { '' }
        $odataType = if ($m.PSObject.Properties['@odata.type']) { $m.'@odata.type' } else { '' }

        $isOwner = $roles -contains 'owner'
        $isGuest = $upn -like '*#EXT#*' -or ($odataType -like '*guest*')
        $assignedRole = if ($isOwner) { 'owner' } elseif ($isGuest) { 'guest' } else { 'member' }

        if ($Role -and $assignedRole -ne $Role) {
            continue
        }

        [PSCustomObject]@{
            TeamId                      = $TeamId
            MembershipId                = if ($m.PSObject.Properties['id']) { $m.id } else { $null }
            UserId                      = if ($m.PSObject.Properties['userId']) { $m.userId } else { $null }
            DisplayName                 = if ($m.PSObject.Properties['displayName']) { $m.displayName } else { $null }
            UserPrincipalName           = $upn
            Email                       = if ($m.PSObject.Properties['email']) { $m.email } else { $null }
            Role                        = $assignedRole
            Roles                       = $roles
            VisibleHistoryStartDateTime = if ($m.PSObject.Properties['visibleHistoryStartDateTime']) { $m.visibleHistoryStartDateTime } else { $null }
        }
    }
}
