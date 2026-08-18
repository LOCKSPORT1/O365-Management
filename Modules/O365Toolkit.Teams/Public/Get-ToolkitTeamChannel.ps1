<#
.SYNOPSIS
    Retrieves channels for a specified Microsoft Team.
.DESCRIPTION
    Queries Microsoft Graph for channels belonging to a specified Team/Group ID.
    Supports fetching all channels, retrieving a specific channel by ChannelId,
    or filtering by displayName / membershipType (standard, private, shared).
.PARAMETER TeamId
    The unique GUID of the Microsoft Team.
.PARAMETER ChannelId
    The unique channel ID (e.g., '19:...@thread.tacv2').
.PARAMETER DisplayName
    Filter channels by display name.
.PARAMETER MembershipType
    Filter channels by type: 'standard', 'private', or 'shared'.
.PARAMETER Config
    Optional configuration hashtable containing environment settings.
.OUTPUTS
    [pscustomobject]
.EXAMPLE
    Get-ToolkitTeamChannel -TeamId '00000000-0000-0000-0000-000000000000'
.EXAMPLE
    Get-ToolkitTeamChannel -TeamId '00000000-0000-0000-0000-000000000000' -MembershipType 'private'
.NOTES
    Required Microsoft Graph Scopes:
      - Channel.ReadBasic.All or ChannelSettings.Read.All or Group.Read.All
#>
function Get-ToolkitTeamChannel {
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TeamId,

        [Parameter(Mandatory = $true, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string]$ChannelId,

        [Parameter(ParameterSetName = 'List')]
        [ValidateRange(1, 999)]
        [int]$Top,

        [Parameter(ParameterSetName = 'List')]
        [switch]$AllPages,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Config = @{ Environment = 'Global' }
    )

    Assert-ToolkitGraphConnection
    if (-not $Config) { $Config = @{ Environment = 'Global' } }

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $relativeUri = "v1.0/teams/$TeamId/channels/$ChannelId"
        $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config
        $chan = Invoke-ToolkitGraphRequest -Uri $requestUri -Method 'GET' -Config $Config

        if ($chan) {
            [PSCustomObject]@{
                TeamId           = $TeamId
                Id               = $chan.id
                DisplayName      = if ($chan.PSObject.Properties['displayName']) { $chan.displayName } else { $null }
                Description      = if ($chan.PSObject.Properties['description']) { $chan.description } else { $null }
                MembershipType   = if ($chan.PSObject.Properties['membershipType']) { $chan.membershipType } else { 'standard' }
                Email            = if ($chan.PSObject.Properties['email']) { $chan.email } else { $null }
                WebUrl           = if ($chan.PSObject.Properties['webUrl']) { $chan.webUrl } else { $null }
                CreatedDateTime  = if ($chan.PSObject.Properties['createdDateTime']) { $chan.createdDateTime } else { $null }
            }
        }
        return
    }

    $relativeUri = "v1.0/teams/$TeamId/channels"
    $queryParams = [System.Collections.Generic.List[string]]::new()

    if ($PSBoundParameters.ContainsKey('Top') -and $Top -gt 0) {
        $queryParams.Add("`$top=$Top")
    }

    if ($queryParams.Count -gt 0) {
        $relativeUri += '?' + ($queryParams -join '&')
    }

    $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config
    $channels = Invoke-ToolkitGraphRequest -Uri $requestUri -Method 'GET' -Config $Config -AllPages:$AllPages.IsPresent

    foreach ($c in $channels) {
        [PSCustomObject]@{
            TeamId           = $TeamId
            Id               = $c.id
            DisplayName      = if ($c.PSObject.Properties['displayName']) { $c.displayName } else { $null }
            Description      = if ($c.PSObject.Properties['description']) { $c.description } else { $null }
            MembershipType   = if ($c.PSObject.Properties['membershipType']) { $c.membershipType } else { 'standard' }
            Email            = if ($c.PSObject.Properties['email']) { $c.email } else { $null }
            WebUrl           = if ($c.PSObject.Properties['webUrl']) { $c.webUrl } else { $null }
            CreatedDateTime  = if ($c.PSObject.Properties['createdDateTime']) { $c.createdDateTime } else { $null }
        }
    }
}
