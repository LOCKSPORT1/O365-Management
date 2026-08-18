# Modules/O365Toolkit.Teams/Public/Get-ToolkitTeamChannel.ps1
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

        [Parameter(ParameterSetName = 'ById', Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ChannelId,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string]$DisplayName,

        [Parameter(ParameterSetName = 'List')]
        [ValidateSet('standard', 'private', 'shared')]
        [string]$MembershipType,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Config = @{ Environment = 'Global' }
    )

    # ---------------------------------------------------------------------------
    # CHANGE: 2026-08-18 - Initial creation of Get-ToolkitTeamChannel for
    # O365Toolkit.Teams adhering to Graph API v1.0 standards and locked lexicon.
    # Module: O365Toolkit.Teams
    # Track: NEUTRAL
    # ---------------------------------------------------------------------------

    Assert-ToolkitGraphConnection

    if (-not $Config) {
        $Config = @{ Environment = 'Global' }
    }

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $relativeUri = "v1.0/teams/$TeamId/channels/$ChannelId"
        $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config

        $requestParams = @{
            Uri    = $requestUri
            Method = 'GET'
            Config = $Config
        }

        $channel = Invoke-ToolkitGraphRequest @requestParams

        if ($channel) {
            [PSCustomObject]@{
                TeamId          = $TeamId
                Id              = $channel.id
                DisplayName     = $channel.displayName
                Description     = $channel.description
                MembershipType  = $channel.membershipType
                Email           = $channel.email
                WebUrl          = $channel.webUrl
                CreatedDateTime = $channel.createdDateTime
                IsArchived      = $channel.isArchived
            }
        }
        return
    }

    $relativeUri = "v1.0/teams/$TeamId/channels"
    $queryParams = [System.Collections.Generic.List[string]]::new()
    $filters = [System.Collections.Generic.List[string]]::new()

    if ($DisplayName) {
        $escapedName = $DisplayName.Replace("'", "''")
        $filters.Add("displayName eq '$escapedName'")
    }

    if ($MembershipType) {
        $filters.Add("membershipType eq '$MembershipType'")
    }

    if ($filters.Count -gt 0) {
        $filterString = [System.Uri]::EscapeDataString(($filters -join ' and '))
        $queryParams.Add("`$filter=$filterString")
    }

    if ($queryParams.Count -gt 0) {
        $relativeUri += '?' + ($queryParams -join '&')
    }

    $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config

    $requestParams = @{
        Uri    = $requestUri
        Method = 'GET'
        Config = $Config
    }

    $channels = Invoke-ToolkitGraphRequest @requestParams

    foreach ($ch in $channels) {
        [PSCustomObject]@{
            TeamId          = $TeamId
            Id              = $ch.id
            DisplayName     = $ch.displayName
            Description     = $ch.description
            MembershipType  = $ch.membershipType
            Email           = $ch.email
            WebUrl          = $ch.webUrl
            CreatedDateTime = $ch.createdDateTime
            IsArchived      = $ch.isArchived
        }
    }
}