function Get-ToolkitIntuneCompliance {
    <#
    .SYNOPSIS
        Queries Microsoft Intune device compliance policies and evaluation statuses via Microsoft Graph API.
    .DESCRIPTION
        Retrieves Intune device compliance policies from the tenant (/v1.0/deviceManagement/deviceCompliancePolicies),
        supporting exact policy lookup, display name filtering, OData query filtering, multi-page retrieval, and configuration forwarding.
    .PARAMETER PolicyId
        Exact unique identifier (GUID) of the device compliance policy.
    .PARAMETER DisplayName
        Filter compliance policies matching a specific display name.
    .PARAMETER Filter
        Raw OData filter string passed directly to Microsoft Graph.
    .PARAMETER Select
        Array of property names to retrieve.
    .PARAMETER All
        Switch to automatically fetch all pages of compliance policies.
    .PARAMETER Config
        Optional custom toolkit configuration hashtable or PSCustomObject.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    param(
        [Parameter(ParameterSetName = 'ByPolicyId', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyId,

        [Parameter(ParameterSetName = 'Query')]
        [string]$DisplayName,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Filter,

        [Parameter(ParameterSetName = 'Query')]
        [Parameter(ParameterSetName = 'ByPolicyId')]
        [string[]]$Select = @('id', 'displayName', 'description', 'createdDateTime', 'lastModifiedDateTime', 'roleScopeTagIds'),

        [Parameter(ParameterSetName = 'Query')]
        [switch]$All,

        [Parameter()]
        [object]$Config
    )

    process {
        if (-not $PSBoundParameters.ContainsKey('Config') -or $null -eq $Config) {
            $Config = @{ Environment = 'Global' }
        }

        $queryParams = [System.Collections.Generic.List[string]]::new()

        if ($PSCmdlet.ParameterSetName -eq 'ByPolicyId') {
            $uri = "deviceManagement/deviceCompliancePolicies/$PolicyId"
        }
        else {
            $uri = "deviceManagement/deviceCompliancePolicies"
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
