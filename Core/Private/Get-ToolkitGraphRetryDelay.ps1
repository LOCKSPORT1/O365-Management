function Get-ToolkitGraphRetryDelay {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Exception,

        [Parameter()]
        [ValidateRange(0, 20)]
        [int]$RetryAttempt = 0,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$MaximumDelaySeconds = 60
    )

    $retryAfterSeconds = $null

    if ($null -ne $Exception) {
        $response = $Exception.Response

        if ($null -ne $response) {
            try {
                $retryAfterHeader =
                    $response.Headers.RetryAfter

                if (
                    $null -ne $retryAfterHeader -and
                    $null -ne $retryAfterHeader.Delta
                ) {
                    $retryAfterSeconds =
                        [math]::Ceiling(
                            $retryAfterHeader.Delta.TotalSeconds
                        )
                }
                elseif (
                    $null -ne $retryAfterHeader -and
                    $null -ne $retryAfterHeader.Date
                ) {
                    $retryAfterSeconds =
                        [math]::Ceiling(
                            (
                                $retryAfterHeader.Date.UtcDateTime -
                                [datetime]::UtcNow
                            ).TotalSeconds
                        )
                }
            }
            catch {
                $retryAfterSeconds = $null
            }

            if ($null -eq $retryAfterSeconds) {
                try {
                    $headerValue =
                        $response.Headers.GetValues(
                            'Retry-After'
                        ) |
                        Select-Object -First 1

                    $parsedDelay = 0

                    if (
                        [int]::TryParse(
                            [string]$headerValue,
                            [ref]$parsedDelay
                        )
                    ) {
                        $retryAfterSeconds = $parsedDelay
                    }
                }
                catch {
                    $retryAfterSeconds = $null
                }
            }
        }
    }

    if (
        $null -ne $retryAfterSeconds -and
        $retryAfterSeconds -gt 0
    ) {
        return [math]::Min(
            $retryAfterSeconds,
            $MaximumDelaySeconds
        )
    }

    $exponentialDelay =
        [math]::Pow(
            2,
            [math]::Min($RetryAttempt, 6)
        )

    $jitterMilliseconds =
        Get-Random `
            -Minimum 100 `
            -Maximum 1000

    $calculatedDelay =
        [math]::Ceiling(
            $exponentialDelay +
            ($jitterMilliseconds / 1000)
        )

    return [math]::Min(
        $calculatedDelay,
        $MaximumDelaySeconds
    )
}