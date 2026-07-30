function Invoke-ToolkitGraphRequest {
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

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [psobject]$Config,

        [Parameter()]
        [hashtable]$Headers,

        [Parameter()]
        [ValidateRange(1, 20)]
        [int]$MaxAttempts = 4,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$MaximumRetryDelaySeconds = 60,

        [Parameter()]
        [switch]$PassThru
    )

    $connection = Test-ToolkitGraphConnection `
        -Config $Config `
        -PassThru

    if (-not $connection.IsValid) {
        throw (
            'No valid Microsoft Graph connection exists. ' +
            'Run Connect-ToolkitGraph before submitting a request.'
        )
    }

    $startedAt = [datetime]::Now
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-ToolkitLog `
        -Config $Config `
        -Component 'GraphRequest' `
        -Level Information `
        -Message (
            "Starting Microsoft Graph request: $Method $Uri; " +
            "Maximum attempts: $MaxAttempts."
        )

    try {
        $requestParameters = @{
    Method                   = $Method
    Uri                      = $Uri
    MaxAttempts              = $MaxAttempts
    MaximumRetryDelaySeconds = $MaximumRetryDelaySeconds
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

$response = Invoke-ToolkitGraphRequestPipeline @requestParameters
        $stopwatch.Stop()
        $completedAt = [datetime]::Now

        Write-ToolkitLog `
            -Config $Config `
            -Component 'GraphRequest' `
            -Level Information `
            -Message (
                "Completed Microsoft Graph request: " +
                "$Method $Uri in " +
                "$($stopwatch.ElapsedMilliseconds) ms."
            )

        if ($PassThru) {
            return [pscustomobject]@{
                Success      = $true
                Method       = $Method
                Uri          = $Uri
                StartedAt    = $startedAt
                CompletedAt  = $completedAt
                Duration     = $stopwatch.Elapsed
                DurationMs   = $stopwatch.ElapsedMilliseconds
                MaxAttempts  = $MaxAttempts
                Data         = $response
            }
        }

        return $response
    }
    catch {
        $stopwatch.Stop()

        $graphError = Resolve-ToolkitGraphError `
            -ErrorRecord $_

        Write-ToolkitLog `
            -Config $Config `
            -Component 'GraphRequest' `
            -Level Error `
            -Message (
                "Microsoft Graph request failed: " +
                "$Method $Uri; " +
                "StatusCode: $($graphError.StatusCode); " +
                "RequestId: $($graphError.RequestId); " +
                "Message: $($graphError.Message)"
            )

        throw
    }
}
