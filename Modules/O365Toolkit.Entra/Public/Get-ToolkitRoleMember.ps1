function Get-ToolkitRoleMember {
    <#
    .SYNOPSIS
        Queries members assigned to a specific Microsoft Entra ID directory role.
    .DESCRIPTION
        Retrieves users, service principals, or groups assigned to a specified 
        directory role using the Microsoft Graph API endpoint: /v1.0/directoryRoles/{RoleId}/members.
    .PARAMETER RoleId
        The unique identifier (GUID) of the directory role whose members you want to query.
    .PARAMETER Select
        Array of property names to retrieve for the role members.
    .PARAMETER Config
        Optional custom toolkit configuration hashtable or PSCustomObject.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByRoleId')]
    param(
        [Parameter(ParameterSetName = 'ByRoleId', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RoleId,

        [Parameter(ParameterSetName = 'ByRoleId')]
        [string[]]$Select = @('id', 'displayName', 'userPrincipalName', 'userType'),

        [Parameter()]
        [object]$Config
    )

    process {
        if (-not $PSBoundParameters.ContainsKey('Config') -or $null -eq $Config) {
            $Config = @{ Environment = 'Global' }
        }

        $queryParams = [System.Collections.Generic.List[string]]::new()
        $uri = "directoryRoles/$RoleId/members"

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