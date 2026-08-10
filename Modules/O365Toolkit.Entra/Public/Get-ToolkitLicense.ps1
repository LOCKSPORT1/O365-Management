function Get-ToolkitLicense {
    <#
    .SYNOPSIS
        Queries Microsoft Entra ID tenant product licenses (subscribed SKUs) via Microsoft Graph API.
    .DESCRIPTION
        Retrieves tenant subscription and licensing information (SKUs, consumed units, 
        prepaid units, and service plans) with support for exact SkuId lookup, 
        SkuPartNumber filtering, and OData filtering.
    .PARAMETER SkuId
        Exact GUID identifier of the subscribed SKU to retrieve.
    .PARAMETER SkuPartNumber
        Filter licenses matching a specific SKU part number string (e.g., SPE_E5, ENTERPRISEPACK).
    .PARAMETER Filter
        Raw OData filter string passed directly to Microsoft Graph.
    .PARAMETER Select
        Array of property names to retrieve.
    .PARAMETER Config
        Optional custom toolkit configuration hashtable or PSCustomObject.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    param(
        [Parameter(ParameterSetName = 'BySkuId', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SkuId,

        [Parameter(ParameterSetName = 'Query')]
        [string]$SkuPartNumber,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Filter,

        [Parameter(ParameterSetName = 'Query')]
        [Parameter(ParameterSetName = 'BySkuId')]
        [string[]]$Select = @('id', 'skuId', 'skuPartNumber', 'appliesTo', 'consumedUnits', 'prepaidUnits', 'servicePlans'),

        [Parameter()]
        [object]$Config
    )

    process {
        if (-not $PSBoundParameters.ContainsKey('Config') -or $null -eq $Config) {
            $Config = @{ Environment = 'Global' }
        }

        $queryParams = [System.Collections.Generic.List[string]]::new()

        if ($PSCmdlet.ParameterSetName -eq 'BySkuId') {
            $queryParams.Add("\$filter=skuId eq '$SkuId'")
            $uri = "v1.0/subscribedSkus"
        }
        else {
            $uri = "v1.0/subscribedSkus"
            $filterParts = [System.Collections.Generic.List[string]]::new()

            if (-not [string]::IsNullOrWhiteSpace($Filter)) {
                $filterParts.Add("($Filter)")
            }
            if (-not [string]::IsNullOrWhiteSpace($SkuPartNumber)) {
                $filterParts.Add("skuPartNumber eq '$SkuPartNumber'")
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
