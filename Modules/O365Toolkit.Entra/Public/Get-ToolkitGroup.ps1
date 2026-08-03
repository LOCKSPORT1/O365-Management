function Get-ToolkitGroup {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$GroupId,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string[]]$Select = @('id', 'displayName', 'description', 'groupTypes', 'mailEnabled', 'securityEnabled'),

        [Parameter(Mandatory = $false)]
        [psobject]$Config
    )

    process {
        $ErrorActionPreference = 'Stop'

        try {
            $invokeArgs = @{
                Method = 'GET'
            }
            if ($PSBoundParameters.ContainsKey('Config') -and $null -ne $Config) {
                $invokeArgs['Config'] = $Config
            }

            if (-not [string]::IsNullOrWhiteSpace($GroupId)) {
                $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId"
                if ($Select.Count -gt 0) {
                    $uri += "?`$select=$($Select -join ',')"
                }

                Write-Verbose "Fetching Entra group by ID: $GroupId"
                $invokeArgs['Uri'] = $uri
                $response = Invoke-ToolkitGraphRequest @invokeArgs
                return [pscustomobject]$response
            }

            $uri = "https://graph.microsoft.com/v1.0/groups"
            $queryParameters = @()

            $effectiveFilter = $Filter
            if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
                $escapedName = $DisplayName -replace "'", "''"
                $displayNameFilter = "displayName eq '$escapedName'"
                if (-not [string]::IsNullOrWhiteSpace($effectiveFilter)) {
                    $effectiveFilter = "($effectiveFilter) and ($displayNameFilter)"
                } else {
                    $effectiveFilter = $displayNameFilter
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($effectiveFilter)) {
                $queryParameters += "`$filter=$([System.Web.HttpUtility]::UrlEncode($effectiveFilter))"
            }

            if ($Select.Count -gt 0) {
                $queryParameters += "`$select=$($Select -join ',')"
            }

            if ($queryParameters.Count -gt 0) {
                $uri += "?" + ($queryParameters -join '&')
            }

            Write-Verbose "Querying Entra groups from Graph URI: $uri"
            $invokeArgs['Uri'] = $uri
            $response = Invoke-ToolkitGraphRequest @invokeArgs

            if ($null -ne $response -and $response.PSObject.Properties['value']) {
                foreach ($item in $response.value) {
                    [pscustomobject]$item
                }
            }
            elseif ($null -ne $response) {
                [pscustomobject]$response
            }
        }
        catch {
            throw "Failed to retrieve Entra group(s): $_"
        }
    }
}
