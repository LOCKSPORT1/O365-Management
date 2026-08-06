function Get-ToolkitDevice {
    <#
    .SYNOPSIS
        Queries Entra ID registered/joined devices via Microsoft Graph API.
    .DESCRIPTION
        Retrieves device records with support for exact DeviceId lookup, 
        operating system or display name filtering, OData $filter expressions, 
        and automatic pagination.
    .PARAMETER DeviceId
        Exact Entra Object ID of the device to retrieve.
    .PARAMETER DisplayName
        Filter devices matching a specific display name.
    .PARAMETER OperatingSystem
        Filter devices matching a specific operating system (e.g. Windows, iOS, Android).
    .PARAMETER Filter
        Raw OData filter string passed directly to Microsoft Graph.
    .PARAMETER Select
        Array of property names to retrieve.
    .PARAMETER AllPages
        When specified, retrieves all matching pages across pagination boundaries.
    .PARAMETER Config
        Optional custom toolkit configuration hashtable or PSCustomObject.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    param(
        [Parameter(ParameterSetName = 'ByDeviceId', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DeviceId,

        [Parameter(ParameterSetName = 'Query')]
        [string]$DisplayName,

        [Parameter(ParameterSetName = 'Query')]
        [string]$OperatingSystem,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Filter,

        [Parameter(ParameterSetName = 'Query')]
        [Parameter(ParameterSetName = 'ByDeviceId')]
        [string[]]$Select = @('id', 'deviceId', 'displayName', 'operatingSystem', 'operatingSystemVersion', 'isCompliant', 'isManaged', 'approximateLastSignInDateTime'),

        [Parameter(ParameterSetName = 'Query')]
        [switch]$AllPages,

        [Parameter()]
        [object]$Config
    )

    process {
        # Fallback to empty hashtable if Config was not supplied (satisfies Mandatory Config param)
        if (-not $PSBoundParameters.ContainsKey('Config') -or $null -eq $Config) {
            $Config = @{ Environment = 'Global' }
        }

        $queryParams = [System.Collections.Generic.List[string]]::new()

        if ($PSCmdlet.ParameterSetName -eq 'ByDeviceId') {
            $uri = "devices/$DeviceId"
        }
        else {
            $uri = "devices"

            $filterParts = [System.Collections.Generic.List[string]]::new()

            if (-not [string]::IsNullOrWhiteSpace($Filter)) {
                $filterParts.Add("($Filter)")
            }
            if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
                $filterParts.Add("displayName eq '$DisplayName'")
            }
            if (-not [string]::IsNullOrWhiteSpace($OperatingSystem)) {
                $filterParts.Add("operatingSystem eq '$OperatingSystem'")
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
            AllPages = $AllPages.IsPresent
            Config   = $Config
        }

        Invoke-ToolkitGraphRequest @requestParams
    }
}
