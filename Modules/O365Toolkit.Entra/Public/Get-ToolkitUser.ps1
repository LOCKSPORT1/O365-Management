function Get-ToolkitUser {
    <#
    .SYNOPSIS
        Queries Entra ID users via Microsoft Graph API.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    param(
        [Parameter(ParameterSetName = 'ByUPN', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UserPrincipalName,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Department,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Filter,

        [Parameter(ParameterSetName = 'Query')]
        [Parameter(ParameterSetName = 'ByUPN')]
        [string[]]$Select = @('id', 'userPrincipalName', 'displayName', 'department', 'mail', 'assignedLicenses'),

        [Parameter(ParameterSetName = 'Query')]
        [switch]$All,

        [Parameter(ParameterSetName = 'Query')]
        [switch]$HasLicenses,

        [Parameter()]
        [object]$Config
    )

    process {
        if (-not $PSBoundParameters.ContainsKey('Config') -or $null -eq $Config) {
            $Config = @{ Environment = 'Global' }
        }

        $queryParams = [System.Collections.Generic.List[string]]::new()

        if ($PSCmdlet.ParameterSetName -eq 'ByUPN') {
            $uri = "users/$UserPrincipalName"
        }
        else {
            $uri = "users"
            $filterParts = [System.Collections.Generic.List[string]]::new()

            if (-not [string]::IsNullOrWhiteSpace($Filter)) {
                $filterParts.Add("($Filter)")
            }
            if (-not [string]::IsNullOrWhiteSpace($Department)) {
                $filterParts.Add("department eq '$Department'")
            }
            if ($HasLicenses.IsPresent) {
                $filterParts.Add("assignedLicenses/`$count ne 0")
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
