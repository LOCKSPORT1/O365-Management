# Modules/O365Toolkit.Teams/Public/Get-ToolkitTeam.ps1
<#
.SYNOPSIS
    Retrieves Microsoft Teams instances from Microsoft Graph.
.DESCRIPTION
    Queries Microsoft Graph for provisioned Microsoft Teams. Supports retrieving a specific
    team by Group/Team ID, filtering by display name or mail nickname, and server-side paging.
    Each returned team includes directory properties and Teams-specific metadata.
.PARAMETER TeamId
    The unique GUID of the Microsoft Team (matches the backing Microsoft 365 Group ID).
.PARAMETER DisplayName
    Filter teams by exact or prefix display name.
.PARAMETER MailNickname
    Filter teams by mail alias / nickname.
.PARAMETER Top
    The maximum number of items to return in a single response page from Microsoft Graph.
.PARAMETER AllPages
    Retrieves all pages of results automatically via @odata.nextLink.
.PARAMETER Config
    Optional configuration hashtable containing environment and endpoint settings.
.OUTPUTS
    [pscustomobject]
.EXAMPLE
    Get-ToolkitTeam -AllPages
.EXAMPLE
    Get-ToolkitTeam -TeamId '00000000-0000-0000-0000-000000000000'
.EXAMPLE
    Get-ToolkitTeam -DisplayName 'Engineering'
.NOTES
    Required Microsoft Graph Scopes:
      - Team.ReadBasic.All or TeamSettings.Read.All or Group.Read.All
#>
function Get-ToolkitTeam {
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ById', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TeamId,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string]$DisplayName,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string]$MailNickname,

        [Parameter(ParameterSetName = 'List')]
        [ValidateRange(1, 999)]
        [int]$Top,

        [Parameter(ParameterSetName = 'List')]
        [switch]$AllPages,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Config = @{ Environment = 'Global' }
    )

    # ---------------------------------------------------------------------------
    # CHANGE: 2026-08-18 - Initial creation of Get-ToolkitTeam for O365Toolkit.Teams
    # adhering to Graph API v1.0 rules (R1.1, R1.2), connection assertion (R1.6),
    # locked lexicon (R2.5), and fallback config normalization (R2.2).
    # Module: O365Toolkit.Teams
    # Track: NEUTRAL
    # ---------------------------------------------------------------------------

    Assert-ToolkitGraphConnection

    if (-not $Config) {
        $Config = @{ Environment = 'Global' }
    }

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $relativeUri = "v1.0/teams/$TeamId"
        $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config

        $requestParams = @{
            Uri    = $requestUri
            Method = 'GET'
            Config = $Config
        }

        $team = Invoke-ToolkitGraphRequest @requestParams

        if ($team) {
            [PSCustomObject]@{
                Id                   = $team.id
                DisplayName          = $team.displayName
                Description          = $team.description
                InternalId           = $team.internalId
                Classification       = $team.classification
                Specialization       = $team.specialization
                Visibility           = $team.visibility
                IsArchived           = $team.isArchived
                WebUrl               = $team.webUrl
                CreatedDateTime      = $team.createdDateTime
                DiscoverySettings    = $team.discoverySettings
                MemberSettings       = $team.memberSettings
                GuestSettings        = $team.guestSettings
                MessagingSettings    = $team.messagingSettings
                FunSettings          = $team.funSettings
            }
        }
        return
    }

    $relativeUri = 'v1.0/groups'
    $queryParams = [System.Collections.Generic.List[string]]::new()
    $filters = [System.Collections.Generic.List[string]]::new()

    # Server-side filter ensuring only Microsoft 365 Groups provisioned as Teams are queried
    $filters.Add("resourceProvisioningOptions/Any(x:x eq 'Team')")

    if ($DisplayName) {
        $escapedName = $DisplayName.Replace("'", "''")
        $filters.Add("displayName eq '$escapedName'")
    }

    if ($MailNickname) {
        $escapedMail = $MailNickname.Replace("'", "''")
        $filters.Add("mailNickname eq '$escapedMail'")
    }

    if ($filters.Count -gt 0) {
        $filterString = [System.Uri]::EscapeDataString(($filters -join ' and '))
        $queryParams.Add("`$filter=$filterString")
    }

    $selectProps = 'id,displayName,description,mailNickname,visibility,createdDateTime,resourceProvisioningOptions'
    $queryParams.Add("`$select=$selectProps")

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

    $groups = Invoke-ToolkitGraphRequest @requestParams

    foreach ($group in $groups) {
        [PSCustomObject]@{
            Id                          = $group.id
            DisplayName                 = $group.displayName
            Description                 = $group.description
            MailNickname                = $group.mailNickname
            Visibility                  = $group.visibility
            CreatedDateTime             = $group.createdDateTime
            ResourceProvisioningOptions = $group.resourceProvisioningOptions
        }
    }
}