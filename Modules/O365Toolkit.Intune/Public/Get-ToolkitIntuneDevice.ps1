function Get-ToolkitIntuneDevice {
    <#
    .SYNOPSIS
        Queries Microsoft Intune managed devices via Microsoft Graph API.
    .DESCRIPTION
        Retrieves managed device inventories from Intune (/v1.0/deviceManagement/managedDevices),
        supporting exact device ID lookup, compliance state filtering, multi-page retrieval, and configuration forwarding.
    .PARAMETER DeviceId
        Exact unique identifier (GUID) of the managed device.
    .PARAMETER DeviceName
        Filter managed devices matching a specific device name.
    .PARAMETER ComplianceState
        Filter devices by compliance state (e.g., compliant, noncompliant, conflict, error, inGracePeriod).
    .PARAMETER Filter
        Raw OData filter string passed directly to Microsoft Graph.
    .PARAMETER Select
        Array of property names to retrieve.
    .PARAMETER All
        Switch to automatically fetch all pages of managed devices.
    .PARAMETER Config
        Optional custom toolkit configuration hashtable or PSCustomObject.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    param(
        [Parameter(ParameterSetName = 'ByDeviceId', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DeviceId,

        [Parameter(ParameterSetName = 'Query')]
        [string]$DeviceName,

        [Parameter(ParameterSetName = 'Query')]
        [ValidateSet('compliant', 'noncompliant', 'conflict', 'error', 'inGracePeriod', 'configManager')]
        [string]$ComplianceState,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Filter,

        [Parameter(ParameterSetName = 'Query')]
        [Parameter(ParameterSetName = 'ByDeviceId')]
        [string[]]$Select = @('id', 'deviceName', 'managedDeviceOwnerType', 'operatingSystem', 'complianceState', 'userPrincipalName', 'lastSyncDateTime'),

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

       if ($PSCmdlet.ParameterSetName -eq 'ByDeviceId') {
            $uri = "v1.0/deviceManagement/managedDevices/$DeviceId"
        }
        else {
            $uri = "v1.0/deviceManagement/managedDevices"
            $filterParts = [System.Collections.Generic.List[string]]::new()

            if (-not [string]::IsNullOrWhiteSpace($Filter)) {
                $filterParts.Add("($Filter)")
            }
            if (-not [string]::IsNullOrWhiteSpace($DeviceName)) {
                $filterParts.Add("deviceName eq '$DeviceName'")
            }
            if (-not [string]::IsNullOrWhiteSpace($ComplianceState)) {
                $filterParts.Add("complianceState eq '$ComplianceState'")
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
