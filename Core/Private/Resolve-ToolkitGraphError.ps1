function Resolve-ToolkitGraphError {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception

    $statusCode = $null
    $requestId = $null
    $clientRequestId = $null
    $responseBody = $null
    $headers = @{}

    if ($null -ne $exception.Response) {
        try {
            $statusCode = [int]$exception.Response.StatusCode
        }
        catch {
            $statusCode = $null
        }

        try {
            foreach ($header in $exception.Response.Headers) {
                $headerName = [string]$header.Key
                $headerValue = @($header.Value) -join ', '

                if (-not [string]::IsNullOrWhiteSpace($headerName)) {
                    $headers[$headerName] = $headerValue
                }
            }
        }
        catch {
            # Some Graph SDK exception types expose headers differently.
        }

        try {
            $requestId = @(
                $exception.Response.Headers.GetValues('request-id')
            ) | Select-Object -First 1
        }
        catch {
            if ($headers.ContainsKey('request-id')) {
                $requestId = $headers['request-id']
            }
        }

        try {
            $clientRequestId = @(
                $exception.Response.Headers.GetValues(
                    'client-request-id'
                )
            ) | Select-Object -First 1
        }
        catch {
            if ($headers.ContainsKey('client-request-id')) {
                $clientRequestId =
                    $headers['client-request-id']
            }
        }
    }

    if (
        $null -eq $statusCode -and
        $null -ne $exception.StatusCode
    ) {
        try {
            $statusCode = [int]$exception.StatusCode
        }
        catch {
            $statusCode = $null
        }
    }

    if (
        $ErrorRecord.ErrorDetails -and
        $ErrorRecord.ErrorDetails.Message
    ) {
        $responseBody =
            $ErrorRecord.ErrorDetails.Message
    }

    if (
        [string]::IsNullOrWhiteSpace($responseBody) -and
        $null -ne $exception.Response
    ) {
        try {
            $responseBody =
                $exception.Response.Content.ReadAsStringAsync().
                    GetAwaiter().
                    GetResult()
        }
        catch {
            $responseBody = $null
        }
    }

    $isRetryable =
        $statusCode -eq 408 -or
        $statusCode -eq 429 -or
        (
            $null -ne $statusCode -and
            $statusCode -ge 500 -and
            $statusCode -le 599
        )

    [pscustomobject]@{
        StatusCode       = $statusCode
        IsRetryable      = $isRetryable
        Headers          = $headers
        RequestId        = $requestId
        ClientRequestId  = $clientRequestId
        Message          = $exception.Message
        ResponseBody     = $responseBody
        ExceptionType    = $exception.GetType().FullName
        FullyQualifiedId = $ErrorRecord.FullyQualifiedErrorId
        ErrorRecord      = $ErrorRecord
    }
}
