function Invoke-GraphRequestWithRetry {
    <#
    .SYNOPSIS
        Sends Microsoft Graph requests with retry and pagination support.

    .DESCRIPTION
        Wraps Invoke-MgGraphRequest and retries requests that fail because of
        throttling or temporary Microsoft Graph service errors.

        For GET requests returning an OData value collection, the function
        follows @odata.nextLink until all pages have been retrieved.

    .PARAMETER Uri
        The Microsoft Graph request URI.

    .PARAMETER Method
        The HTTP method used for the request.

    .PARAMETER Body
        Optional request body for POST, PUT, or PATCH requests.

    .PARAMETER Headers
        Optional HTTP request headers.

    .PARAMETER MaxRetryCount
        Maximum number of retries for each request.

    .PARAMETER InitialRetryDelaySeconds
        Initial retry delay. The delay increases exponentially after each retry.

    .PARAMETER DisablePagination
        Prevents the function from following @odata.nextLink.

    .EXAMPLE
        Invoke-GraphRequestWithRetry `
            -Method GET `
            -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices'

    .EXAMPLE
        Invoke-GraphRequestWithRetry `
            -Method PATCH `
            -Uri $Uri `
            -Body $Body
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter()]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',

        [Parameter()]
        [object]$Body,

        [Parameter()]
        [hashtable]$Headers,

        [Parameter()]
        [ValidateRange(0, 20)]
        [int]$MaxRetryCount = 5,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$InitialRetryDelaySeconds = 2,

        [Parameter()]
        [switch]$DisablePagination
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $allResults = [System.Collections.Generic.List[object]]::new()
    $currentUri = $Uri
    $pageNumber = 0
    $lastResponse = $null

    do {
        $pageNumber++
        $retryAttempt = 0
        $requestCompleted = $false

        do {
            try {
                $requestParameters = @{
                    Method      = $Method
                    Uri         = $currentUri
                    OutputType  = 'PSObject'
                    ErrorAction = 'Stop'
                }

                if ($PSBoundParameters.ContainsKey('Body')) {
                    if ($Body -is [string]) {
                        $requestParameters.Body = $Body
                    }
                    else {
                        $requestParameters.Body = $Body | ConvertTo-Json -Depth 20
                    }

                    $requestParameters.ContentType = 'application/json'
                }

                if ($PSBoundParameters.ContainsKey('Headers')) {
                    $requestParameters.Headers = $Headers
                }

                Write-Verbose (
                    'Sending Graph request. Method: {0}; Page: {1}; Attempt: {2}; URI: {3}' -f
                    $Method,
                    $pageNumber,
                    ($retryAttempt + 1),
                    $currentUri
                )

                $lastResponse = Invoke-MgGraphRequest @requestParameters
                $requestCompleted = $true
            }
            catch {
                $retryAttempt++

                $statusCode = $null
                $retryAfterSeconds = $null

                if ($_.Exception.Response) {
                    try {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                    }
                    catch {
                        $statusCode = $null
                    }

                    try {
                        $retryAfterHeader = $_.Exception.Response.Headers.RetryAfter

                        if ($retryAfterHeader.Delta) {
                            $retryAfterSeconds = [int][math]::Ceiling(
                                $retryAfterHeader.Delta.TotalSeconds
                            )
                        }
                    }
                    catch {
                        $retryAfterSeconds = $null
                    }
                }

                $isRetryableStatus = $statusCode -in @(
                    408,
                    429,
                    500,
                    502,
                    503,
                    504
                )

                if (
                    -not $isRetryableStatus -or
                    $retryAttempt -gt $MaxRetryCount
                ) {
                    throw (
                        'Microsoft Graph request failed. Method: {0}; URI: {1}; Status: {2}; Error: {3}' -f
                        $Method,
                        $currentUri,
                        $(if ($statusCode) { $statusCode } else { 'Unknown' }),
                        $_.Exception.Message
                    )
                }

                if (-not $retryAfterSeconds) {
                    $retryAfterSeconds = [math]::Min(
                        300,
                        $InitialRetryDelaySeconds *
                        [math]::Pow(2, ($retryAttempt - 1))
                    )
                }

                Write-Warning (
                    'Graph request temporarily failed with status {0}. ' +
                    'Retrying in {1} seconds. Attempt {2} of {3}.' -f
                    $statusCode,
                    $retryAfterSeconds,
                    $retryAttempt,
                    $MaxRetryCount
                )

                Start-Sleep -Seconds $retryAfterSeconds
            }
        }
        until ($requestCompleted)

        $isCollectionResponse =
            $null -ne $lastResponse -and
            $lastResponse.PSObject.Properties.Name -contains 'value'

        if ($isCollectionResponse) {
            foreach ($item in @($lastResponse.value)) {
                $allResults.Add($item)
            }
        }

        $nextLink = $null

        if (
            $Method -eq 'GET' -and
            -not $DisablePagination -and
            $null -ne $lastResponse -and
            $lastResponse.PSObject.Properties.Name -contains '@odata.nextLink'
        ) {
            $nextLink = $lastResponse.'@odata.nextLink'
        }

        $currentUri = $nextLink
    }
    while ($currentUri)

    if ($allResults.Count -gt 0) {
        return [pscustomobject]@{
            value = $allResults.ToArray()
        }
    }

    return $lastResponse
}