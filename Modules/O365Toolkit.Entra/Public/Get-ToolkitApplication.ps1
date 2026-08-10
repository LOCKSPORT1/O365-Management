function Get-ToolkitApplication {
    <#
    .SYNOPSIS
        Queries Microsoft Entra ID application registrations via Microsoft Graph API.
    .DESCRIPTION
        Retrieves application registration objects in the tenant, supporting exact ID or appId lookup,
        displayName filtering, OData filtering, multi-page retrieval, and configuration forwarding.
    .PARAMETER ApplicationId
        Exact unique identifier (GUID) of the application object.
    .PARAMETER AppId
        Exact Application (client) ID associated with the application registration.
    .PARAMETER DisplayName
        Filter applications matching a specific display name.
    .PARAMETER Filter
        Raw OData filter string passed directly to Microsoft Graph.
    .PARAMETER Select
        Array of property names to retrieve (defaults to core identity, key credentials, and identifiers).
    .PARAMETER All
        Switch to automatically fetch all pages of applications.
    .PARAMETER Config
        Optional custom toolkit configuration hashtable or PSCustomObject.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    param(
        [Parameter(ParameterSetName = 'ByApplicationId', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ApplicationId,

        [Parameter(ParameterSetName = 'ByAppId', Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AppId,

        [Parameter(ParameterSetName = 'Query', Mandatory = $false)]
        [string]$DisplayName,

        [Parameter(ParameterSetName = 'Query', Mandatory = $false)]
        [string]$Filter,

        [Parameter(ParameterSetName = 'Query', Mandatory = $false)]
        [string[]]$Select = @('id', 'appId', 'displayName', 'createdDateTime', 'keyCredentials', 'passwordCredentials', 'requiredResourceAccess'),

        [Parameter(ParameterSetName = 'Query', Mandatory = $false)]
        [switch]$All,

        [Parameter(Mandatory = $false)]
        [object]$Config
    )

    process {
        if (-not $Config -or $Config -isnot [hashtable] -and $Config -isnot [pscustomobject]) {
            $Config = @{ Environment = 'Global' }
        }

        $queryParams = [System.Collections.Generic.List[string]]::new()

        if ($PSCmdlet.ParameterSetName -eq 'ByApplicationId') {
            $uri = "v1.0/applications/$ApplicationId"
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByAppId') {
            $queryParams.Add("\$filter=appId eq '$AppId'")
            $uri = "v1.0/applications"
        }
        else {
            $uri = "v1.0/applications"
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

        if ($All.IsPresent) {
            $requestParams.All = $true
        }

        Invoke-ToolkitGraphRequest @requestParams
    }
}
