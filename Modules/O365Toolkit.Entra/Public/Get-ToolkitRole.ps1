function Get-ToolkitRole {
    <#
    .SYNOPSIS
        Queries Microsoft Entra ID directory roles via Microsoft Graph API.
    .DESCRIPTION
        Retrieves directory roles active in the tenant, supporting exact role ID lookup, 
        DisplayName filtering, OData filtering, and configuration forwarding.
    .PARAMETER RoleId
        Exact unique identifier (GUID) of the directory role to retrieve.
    .PARAMETER DisplayName
        Filter roles matching a specific display name (e.g., 'Global Administrator').
    .PARAMETER Filter
        Raw OData filter string passed directly to Microsoft Graph.
    .PARAMETER Select
        Array of property names to retrieve.
    .PARAMETER Config
        Optional custom toolkit configuration hashtable or PSCustomObject.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    param(
        [Parameter(ParameterSetName = 'ByRoleId', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RoleId,

        [Parameter(ParameterSetName = 'Query')]
        [string]$DisplayName,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Filter,

        [Parameter(ParameterSetName = 'Query')]
        [Parameter(ParameterSetName = 'ByRoleId')]
        [string[]]$Select = @('id', 'displayName', 'description', 'roleTemplateId'),

        [Parameter()]
        [object]$Config
    )

    process {
        # Fallback safeguard against parameter prompting loops
        if (-not $PSBoundParameters.ContainsKey('Config') -or $null -eq $Config) {
            $Config = @{ Environment = 'Global' }
        }

        $queryParams = [System.Collections.Generic.List[string]]::new()

        if ($PSCmdlet.ParameterSetName -eq 'ByRoleId') {
            $uri = "directoryRoles/$RoleId"
        }
        else {
            $uri = "directoryRoles"
            $filterParts = [System.Collections.Generic.List[string]]::new()

            if (-not [string]::IsNullOrWhiteSpace($Filter)) {
                $filterParts.Add("($Filter)")
            }
            if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
                $filterParts.Add("displayName eq '$DisplayName'")
            }

            if ($filterParts.Count -gt 0) {
                $queryParams.Add('$filter=' + ($filterParts -join ' and '))
            }
        }

        if ($Select -and $Select.Count -gt 0) {
            $queryParams.Add('$select=' + ($Select -join ','))
        }

        if ($queryParams.Count -gt 0) {
            $uri += "?" + ($queryParams -join "&")
        }

        $requestParams = @{
            Method   = 'GET'
            Uri      = $uri
            Config   = $Config
        }

        Invoke-ToolkitGraphRequest @requestParams
    }
}