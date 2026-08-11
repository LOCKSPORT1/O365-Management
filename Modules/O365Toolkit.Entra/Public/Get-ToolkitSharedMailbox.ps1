function Get-ToolkitSharedMailbox {
    <#
    .SYNOPSIS
        Queries Exchange Online shared mailboxes and delegation permissions via Microsoft Graph API.
    .DESCRIPTION
        Retrieves shared mailboxes from Microsoft Graph (/v1.0/users?$filter=mailboxSettings/userType eq 'Shared' or similar, 
        or user accounts with recipientTypeDetails), supporting exact UPN lookup, display name filtering, 
        and automatic pagination.
    .PARAMETER Identity
        Exact User Principal Name (UPN) or display name of the shared mailbox.
    .PARAMETER Filter
        Raw OData filter string passed directly to Microsoft Graph.
    .PARAMETER Select
        Array of property names to retrieve.
    .PARAMETER All
        Switch to automatically fetch all pages of shared mailboxes.
    .PARAMETER Config
        Optional custom toolkit configuration hashtable or PSCustomObject.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    param(
        [Parameter(ParameterSetName = 'ByIdentity', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Identity,

        [Parameter(ParameterSetName = 'Query')]
        [string]$Filter,

        [Parameter(ParameterSetName = 'Query')]
        [Parameter(ParameterSetName = 'ByIdentity')]
        [string[]]$Select = @('id', 'displayName', 'mail', 'userPrincipalName', 'mailboxSettings', 'assignedLicenses'),

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

        # Target users endpoint filtered for shared mailbox characteristics in Graph
        if ($PSCmdlet.ParameterSetName -eq 'ByIdentity') {
            if ($Identity -match '@') {
                $queryParams.Add("\$filter=userPrincipalName eq '$Identity'")
            }
            else {
                $queryParams.Add("\$filter=displayName eq '$Identity'")
            }
            $uri = "users"
        }
        else {
            $uri = "users"
            $filterParts = [System.Collections.Generic.List[string]]::new()
            
            # Default Graph filter targeting shared mailboxes or custom OData filter
            if (-not [string]::IsNullOrWhiteSpace($Filter)) {
                $filterParts.Add("($Filter)")
            }
            else {
                # Graph query standard for shared mailboxes often checks assignment/mailboxSettings
                $filterParts.Add("mailboxSettings/userType eq 'Shared'")
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