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
        $relativeUri = "v1.0/teams/$TeamId"
        $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config
        $team = Invoke-ToolkitGraphRequest -Uri $requestUri -Method 'GET' -Config $Config

        if ($team) {
            [PSCustomObject]@{
                Id                   = $team.id
                DisplayName          = if ($team.PSObject.Properties['displayName']) { $team.displayName } else { $null }
                Description          = if ($team.PSObject.Properties['description']) { $team.description } else { $null }
                InternalId           = if ($team.PSObject.Properties['internalId']) { $team.internalId } else { $null }
                MailNickname         = if ($team.PSObject.Properties['mailNickname']) { $team.mailNickname } else { $null }
                Classification       = if ($team.PSObject.Properties['classification']) { $team.classification } else { $null }
                Specialization       = if ($team.PSObject.Properties['specialization']) { $team.specialization } else { $null }
                Visibility           = if ($team.PSObject.Properties['visibility']) { $team.visibility } else { $null }
                WebUrl               = if ($team.PSObject.Properties['webUrl']) { $team.webUrl } else { $null }
                IsArchived           = if ($team.PSObject.Properties['isArchived']) { $team.isArchived } else { $false }
                CreatedDateTime      = if ($team.PSObject.Properties['createdDateTime']) { $team.createdDateTime } else { $null }
            }
        }
        return
    }

    $relativeUri = "v1.0/groups?`$filter=resourceProvisioningOptions/Any(x:x eq 'Team')"
    $queryParams = [System.Collections.Generic.List[string]]::new()

    if ($DisplayName) {
        $escapedName = $DisplayName.Replace("'", "''")
        $relativeUri += " and startswith(displayName,'$escapedName')"
    }

    if ($PSBoundParameters.ContainsKey('Top') -and $Top -gt 0) {
        $queryParams.Add("`$top=$Top")
    }

    if ($queryParams.Count -gt 0) {
        $relativeUri += '&' + ($queryParams -join '&')
    }

    $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config
    $teams = Invoke-ToolkitGraphRequest -Uri $requestUri -Method 'GET' -Config $Config -AllPages:$AllPages.IsPresent

    foreach ($t in $teams) {
        [PSCustomObject]@{
            Id                   = $t.id
            DisplayName          = if ($t.PSObject.Properties['displayName']) { $t.displayName } else { $null }
            Description          = if ($t.PSObject.Properties['description']) { $t.description } else { $null }
            InternalId           = if ($t.PSObject.Properties['internalId']) { $t.internalId } else { $null }
            MailNickname         = if ($t.PSObject.Properties['mailNickname']) { $t.mailNickname } else { $null }
            Classification       = if ($t.PSObject.Properties['classification']) { $t.classification } else { $null }
            Specialization       = if ($t.PSObject.Properties['specialization']) { $t.specialization } else { $null }
            Visibility           = if ($t.PSObject.Properties['visibility']) { $t.visibility } else { $null }
            WebUrl               = if ($t.PSObject.Properties['webUrl']) { $t.webUrl } else { $null }
            IsArchived           = if ($t.PSObject.Properties['isArchived']) { $t.isArchived } else { $false }
            CreatedDateTime      = if ($t.PSObject.Properties['createdDateTime']) { $t.createdDateTime } else { $null }
        }
    }
}
