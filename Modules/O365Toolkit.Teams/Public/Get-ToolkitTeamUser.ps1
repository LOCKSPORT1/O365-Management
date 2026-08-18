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
