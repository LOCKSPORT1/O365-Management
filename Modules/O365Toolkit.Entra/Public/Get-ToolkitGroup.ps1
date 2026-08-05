function Get-ToolkitGroup {
    [CmdletBinding(DefaultParameterSetName = 'All')]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$GroupId,

        [Parameter(ParameterSetName = 'BySearch')]
        [string]$DisplayName,

        [Parameter(ParameterSetName = 'BySearch')]
        [ValidateSet('Unified', 'Security', 'MailEnabledSecurity', 'Distribution')]
        [string]$GroupType,

        [Parameter(ParameterSetName = 'ByFilter')]
        [string]$Filter,

        [Parameter(ParameterSetName = 'All')]
        [switch]$All,

        [Parameter()]
        [string[]]$Select = @('id', 'displayName', 'groupTypes', 'mailEnabled', 'securityEnabled', 'mail'),

        [Parameter()]
        [pscustomobject]$Config
    )

    process {
        $baseUri = "https://graph.microsoft.com/v1.0/groups"
        $queryParams = @()
        $headers = @{}

        if ($Select) {
            $queryParams += "`$select=$($Select -join ',')"
        }

        switch ($PSCmdlet.ParameterSetName) {
            'ById' {
                $baseUri = "$baseUri/$GroupId"
            }
            'BySearch' {
                $filters = @()
                if ($DisplayName) {
                    $filters += "startsWith(displayName,'$DisplayName')"
                }
                if ($GroupType) {
                    switch ($GroupType) {
                        'Unified'             { $filters += "groupTypes/any(c:c eq 'Unified')" }
                        'Security'            { $filters += "securityEnabled eq true and mailEnabled eq false" }
                        'MailEnabledSecurity' { $filters += "securityEnabled eq true and mailEnabled eq true" }
                        'Distribution'        { $filters += "securityEnabled eq false and mailEnabled eq true" }
                    }
                }
                if ($filters.Count -gt 0) {
                    $queryParams += "`$filter=$($filters -join ' and ')"
                    $headers['ConsistencyLevel'] = 'eventual'
                    $queryParams += "`$count=true"
                }
            }
            'ByFilter' {
                if ($Filter) {
                    $queryParams += "`$filter=$Filter"
                    $headers['ConsistencyLevel'] = 'eventual'
                    $queryParams += "`$count=true"
                }
            }
        }

        # Construct complete Graph URL
        $finalUri = $baseUri
        if ($queryParams.Count -gt 0 -and $PSCmdlet.ParameterSetName -ne 'ById') {
            $finalUri = "$baseUri?$( $queryParams -join '&' )"
        }

        # Exact parameter splat matching Invoke-ToolkitGraphRequest
        $requestParams = @{
            Method   = 'GET'
            Uri      = $finalUri
            Headers  = $headers
            AllPages = $All
        }

        if ($PSBoundParameters.ContainsKey('Config')) {
            $requestParams['Config'] = $Config
        }

        Invoke-ToolkitGraphRequest @requestParams
    }
}
