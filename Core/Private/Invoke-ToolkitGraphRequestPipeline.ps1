function Invoke-ToolkitGraphRequestPipeline {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'GET',
            'POST',
            'PATCH',
            'PUT',
            'DELETE'
        )]
        [string]$Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter()]
        [AllowNull()]
        [object]$Body,

        [Parameter()]
        [hashtable]$Headers,

        [Parameter()]
        [ValidateRange(1, 20)]
        [int]$MaxAttempts = 4,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$MaximumRetryDelaySeconds = 60
    )

    $requestParameters = @{
        Method              = $Method
        Uri                 = $Uri
        MaxAttempts         = $MaxAttempts
        MaximumDelaySeconds = $MaximumRetryDelaySeconds
    }

    if ($PSBoundParameters.ContainsKey('Body')) {
        $requestParameters.Body = $Body
    }

    if (
        $PSBoundParameters.ContainsKey('Headers') -and
        $null -ne $Headers
    ) {
        $requestParameters.Headers = $Headers
    }

    Invoke-GraphRequestWithRetry @requestParameters
}
