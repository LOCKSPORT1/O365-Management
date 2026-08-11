function Get-ToolkitIntuneApp {
    <#
    .SYNOPSIS
        Queries Microsoft Intune mobile applications and Win32 packages via Microsoft Graph API.
    .DESCRIPTION
        Retrieves applications managed in Intune (/v1.0/deviceAppManagement/mobileApps),
        supporting exact app ID lookups, display name filters, OData filtering, multi-page retrieval, and configuration forwarding.
    .PARAMETER AppId
        Exact unique identifier (GUID) of the mobile application.
    .PARAMETER DisplayName
        Filter applications matching a specific display name.
    .PARAMETER Filter
        Raw OData filter string passed directly to Microsoft Graph.
    .PARAMETER Select
        Array of property names to retrieve.
    .PARAMETER All
        Switch to automatically fetch all pages of applications.
    .PARAMETER Config
        Optional custom toolkit configuration hashtable or PSCustomObject.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    param(
        [Parameter(ParameterSetName = 'ByAppId', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AppId,

        [Parameter(ParameterSetName = 'Query')]
        [string]$DisplayName,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Filter,

        [Parameter(ParameterSetName = 'Query')]
        [Parameter(ParameterSetName = 'ByAppId')]
        [string[]]$Select = @('id', 'displayName', 'description', 'publisher', 'createdDateTime', 'lastModifiedDateTime', '@odata.type'),

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

        if ($PSCmdlet.ParameterSetName -eq 'ByAppId') {
            $uri = "deviceAppManagement/mobileApps/$AppId"
        }
        else {
            $uri = "deviceAppManagement/mobileApps"
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
