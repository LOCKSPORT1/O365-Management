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
        [switch]$AllPages,

        [Parameter()]
        [ValidateRange(0, 10000)]
        [int]$PageLimit = 0,

        [Parameter()]
        [switch]$PassThru
    )

    if ($AllPages -and $Method -ne 'GET') {
        throw 'The AllPages parameter can only be used with GET requests.'
    }

    if ($PageLimit -gt 0 -and -not $AllPages) {
        throw 'PageLimit can only be used when AllPages is specified.'
    }

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
            "Maximum attempts: $MaxAttempts; " +
            "All pages: $([bool]$AllPages); " +
            "Page limit: $PageLimit."
        )

    try {
        if ($AllPages) {
            $pagedParameters = @{
                Uri                      = $Uri
                MaxAttempts              = $MaxAttempts
                MaximumRetryDelaySeconds = $MaximumRetryDelaySeconds
                PageLimit                = $PageLimit
            }

            if (
                $PSBoundParameters.ContainsKey('Headers') -and
                $null -ne $Headers
            ) {
                $pagedParameters.Headers = $Headers
            }

            $pagedResult = Invoke-ToolkitGraphPagedRequest `
                @pagedParameters

            $response = $pagedResult.Records
        }
        else {
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

            $response = Invoke-ToolkitGraphRequestPipeline `
                @requestParameters
        }

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
            $result = [ordered]@{
                Success     = $true
                Method      = $Method
                Uri         = $Uri
                StartedAt   = $startedAt
                CompletedAt = $completedAt
                Duration    = $stopwatch.Elapsed
                DurationMs  = $stopwatch.ElapsedMilliseconds
                MaxAttempts = $MaxAttempts
                AllPages    = [bool]$AllPages
                Data        = $response
            }

            if ($AllPages) {
                $result.PageCount = $pagedResult.PageCount
                $result.RecordCount = $pagedResult.RecordCount
                $result.IsTruncated = $pagedResult.IsTruncated
                $result.PageLimit = $pagedResult.PageLimit
            }

            return [pscustomobject]$result
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