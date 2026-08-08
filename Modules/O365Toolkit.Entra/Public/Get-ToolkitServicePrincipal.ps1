function Get-ToolkitServicePrincipal {
    <#
    .SYNOPSIS
        Queries Microsoft Entra ID enterprise applications (service principals) via Microsoft Graph API.
    .DESCRIPTION
        Retrieves service principals registered in the tenant, supporting exact ID or appId lookup,
        displayName filtering, OData filtering, multi-page retrieval, and configuration forwarding.
    .PARAMETER ServicePrincipalId
        Exact unique identifier (GUID) of the service principal object.
    .PARAMETER AppId
        Exact Application (client) ID associated with the service principal.
    .PARAMETER DisplayName
        Filter service principals matching a specific display name.
    .PARAMETER Filter
        Raw OData filter string passed directly to Microsoft Graph.
    .PARAMETER Select
        Array of property names to retrieve (defaults to key app identity and credential metadata).
    .PARAMETER All
        Switch to automatically fetch all pages of service principals.
    .PARAMETER Config
        Optional custom toolkit configuration hashtable or PSCustomObject.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    param(
        [Parameter(ParameterSetName = 'ByServicePrincipalId', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ServicePrincipalId,

        [Parameter(ParameterSetName = 'ByAppId', Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AppId,

        [Parameter(ParameterSetName = 'Query')]
        [string]$DisplayName,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Filter,

        [Parameter(ParameterSetName = 'Query')]
        [Parameter(ParameterSetName = 'ByServicePrincipalId')]
        [Parameter(ParameterSetName = 'ByAppId')]
        [string[]]$Select = @('id', 'appId', 'displayName', 'servicePrincipalType', 'accountEnabled', 'keyCredentials', 'passwordCredentials'),

        [Parameter(ParameterSetName = 'Query')]
        [switch]$All,

        [Parameter()]
        [object]$Config
    )

    process {
        # Fallback safeguard against parameter prompting loops
        if (-not $PSBoundParameters.ContainsKey('Config') -or $null -eq $Config) {
            $Config = @{ Environment = 'Global' }
        }

        $queryParams = [System.Collections.Generic.List[string]]::new()

        if ($PSCmdlet.ParameterSetName -eq 'ByServicePrincipalId') {
            $uri = "servicePrincipals/$ServicePrincipalId"
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByAppId') {
            $queryParams.Add("\$filter=appId eq '$AppId'")
            $uri = "servicePrincipals"
        }
        else {
            $uri = "servicePrincipals"
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
            AllPages = $All.IsPresent
            Config   = $Config
        }

        Invoke-ToolkitGraphRequest @requestParams
    }
}