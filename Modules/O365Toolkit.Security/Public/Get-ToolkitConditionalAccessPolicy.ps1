<#
.SYNOPSIS
    Retrieves Microsoft Entra ID Conditional Access policies from Microsoft Graph.
.DESCRIPTION
    Queries the Microsoft Graph v1.0/identity/conditionalAccess/policies endpoint.
    Supports querying all policies, retrieving an individual policy by PolicyId,
    or filtering by displayName and policy state (enabled, disabled, enabledForReportingButNotEnforced).
.PARAMETER PolicyId
    The unique GUID identifier of the Conditional Access policy.
.PARAMETER DisplayName
    Filter policies by exact or prefix display name.
.PARAMETER State
    Filter policies by state: 'enabled', 'disabled', or 'enabledForReportingButNotEnforced'.
.PARAMETER Top
    The maximum number of items to return in a single page.
.PARAMETER AllPages
    Retrieves all pages of results automatically via @odata.nextLink.
.PARAMETER Config
    Optional configuration hashtable containing environment settings.
.OUTPUTS
    [pscustomobject]
.EXAMPLE
    Get-ToolkitConditionalAccessPolicy -AllPages
.EXAMPLE
    Get-ToolkitConditionalAccessPolicy -PolicyId '00000000-0000-0000-0000-000000000000'
.EXAMPLE
    Get-ToolkitConditionalAccessPolicy -State 'enabled'
.NOTES
    Required Microsoft Graph Scopes:
      - Policy.Read.All or Policy.Read.ConditionalAccess
#>
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
