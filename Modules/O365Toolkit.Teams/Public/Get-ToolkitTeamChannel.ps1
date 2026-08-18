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
