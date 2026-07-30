function Invoke-GraphRequestWithRetry {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
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
        [int]$MaximumDelaySeconds = 60
    )

    $attempt = 0

    while ($attempt -lt $MaxAttempts) {
        $attempt++

        try {
            $requestParameters = @{
                Method      = $Method
                Uri         = $Uri
                OutputType  = 'PSObject'
                ErrorAction = 'Stop'
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

            return Invoke-MgGraphRequest @requestParameters
        }
        catch {
            $resolvedError = Resolve-ToolkitGraphError `
                -ErrorRecord $_

            $isFinalAttempt = $attempt -ge $MaxAttempts

            if (
                -not $resolvedError.IsRetryable -or
                $isFinalAttempt
            ) {
                throw
            }

           $delaySeconds = Get-ToolkitGraphRetryDelay `
    -Exception $_.Exception `
    -RetryAttempt $attempt `
    -MaximumDelaySeconds $MaximumDelaySeconds

          $retryMessage = (
    'Microsoft Graph request failed with retryable status {0}. ' +
    'Retrying attempt {1} of {2} in {3} second(s).'
) -f `
    $resolvedError.StatusCode,
    ($attempt + 1),
    $MaxAttempts,
    $delaySeconds

Write-Verbose $retryMessage

            Start-Sleep -Seconds $delaySeconds
        }
    }
}