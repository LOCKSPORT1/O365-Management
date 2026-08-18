function Get-ToolkitConditionalAccessPolicy {
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ById', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyId,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string]$DisplayName,

        [Parameter(ParameterSetName = 'List')]
        [ValidateSet('enabled', 'disabled', 'enabledForReportingButNotEnforced')]
        [string]$State,

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
        $relativeUri = "v1.0/identity/conditionalAccess/policies/$PolicyId"
        $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config
        $policy = Invoke-ToolkitGraphRequest -Uri $requestUri -Method 'GET' -Config $Config

        if ($policy) {
            [PSCustomObject]@{
                Id                   = $policy.id
                DisplayName          = if ($policy.PSObject.Properties['displayName']) { $policy.displayName } else { $null }
                State                = if ($policy.PSObject.Properties['state']) { $policy.state } else { $null }
                CreatedDateTime      = if ($policy.PSObject.Properties['createdDateTime']) { $policy.createdDateTime } else { $null }
                ModifiedDateTime     = if ($policy.PSObject.Properties['modifiedDateTime']) { $policy.modifiedDateTime } else { $null }
                Conditions           = if ($policy.PSObject.Properties['conditions']) { $policy.conditions } else { $null }
                GrantControls        = if ($policy.PSObject.Properties['grantControls']) { $policy.grantControls } else { $null }
                SessionControls      = if ($policy.PSObject.Properties['sessionControls']) { $policy.sessionControls } else { $null }
            }
        }
        return
    }

    $relativeUri = 'v1.0/identity/conditionalAccess/policies'
    $queryParams = [System.Collections.Generic.List[string]]::new()
    $filters = [System.Collections.Generic.List[string]]::new()

    if ($DisplayName) {
        $escapedName = $DisplayName.Replace("'", "''")
        $filters.Add("displayName eq '$escapedName'")
    }

    if ($State) {
        $filters.Add("state eq '$State'")
    }

    if ($filters.Count -gt 0) {
        $filterString = [System.Uri]::EscapeDataString(($filters -join ' and '))
        $queryParams.Add("`$filter=$filterString")
    }

    if ($PSBoundParameters.ContainsKey('Top') -and $Top -gt 0) {
        $queryParams.Add("`$top=$Top")
    }

    if ($queryParams.Count -gt 0) {
        $relativeUri += '?' + ($queryParams -join '&')
    }

    $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config
    $policies = Invoke-ToolkitGraphRequest -Uri $requestUri -Method 'GET' -Config $Config -AllPages:$AllPages.IsPresent

    foreach ($p in $policies) {
        [PSCustomObject]@{
            Id               = $p.id
            DisplayName      = if ($p.PSObject.Properties['displayName']) { $p.displayName } else { $null }
            State            = if ($p.PSObject.Properties['state']) { $p.state } else { $null }
            CreatedDateTime  = if ($p.PSObject.Properties['createdDateTime']) { $p.createdDateTime } else { $null }
            ModifiedDateTime = if ($p.PSObject.Properties['modifiedDateTime']) { $p.modifiedDateTime } else { $null }
            Conditions       = if ($p.PSObject.Properties['conditions']) { $p.conditions } else { $null }
            GrantControls    = if ($p.PSObject.Properties['grantControls']) { $p.grantControls } else { $null }
            SessionControls  = if ($p.PSObject.Properties['sessionControls']) { $p.sessionControls } else { $null }
        }
    }
}
