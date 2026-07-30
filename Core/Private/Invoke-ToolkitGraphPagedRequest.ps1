function Invoke-ToolkitGraphPagedRequest {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter()]
        [hashtable]$Headers,

        [Parameter()]
        [ValidateRange(1, 20)]
        [int]$MaxAttempts = 4,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$MaximumRetryDelaySeconds = 60,

        [Parameter()]
        [ValidateRange(0, 10000)]
        [int]$PageLimit = 0
    )

    $records = [System.Collections.Generic.List[object]]::new()

    $currentUri = $Uri
    $pageCount = 0
    $isTruncated = $false

    while (
        -not [string]::IsNullOrWhiteSpace($currentUri)
    ) {
        $requestParameters = @{
            Method                   = 'GET'
            Uri                      = $currentUri
            MaxAttempts              = $MaxAttempts
            MaximumRetryDelaySeconds = $MaximumRetryDelaySeconds
        }

        if (
            $PSBoundParameters.ContainsKey('Headers') -and
            $null -ne $Headers
        ) {
            $requestParameters.Headers = $Headers
        }

        $response = Invoke-ToolkitGraphRequestPipeline `
            @requestParameters

        $pageCount++

        $value = $null

        if ($response -is [System.Collections.IDictionary]) {
            if ($response.Contains('value')) {
                $value = $response['value']
            }
        }
        else {
            $valueProperty = $response.PSObject.Properties['value']

            if ($null -ne $valueProperty) {
                $value = $valueProperty.Value
            }
        }

        if ($null -eq $value) {
            throw (
                "Microsoft Graph response for '$currentUri' " +
                "did not contain a value collection."
            )
        }

        foreach ($item in @($value)) {
            [void]$records.Add($item)
        }

        $nextLink = Get-ToolkitGraphNextLink `
            -Response $response

        if (
            $PageLimit -gt 0 -and
            $pageCount -ge $PageLimit -and
            -not [string]::IsNullOrWhiteSpace($nextLink)
        ) {
            $isTruncated = $true
            break
        }

        $currentUri = $nextLink
    }

    return [pscustomobject]@{
        Records     = $records.ToArray()
        RecordCount = $records.Count
        PageCount   = $pageCount
        IsTruncated = $isTruncated
        PageLimit   = $PageLimit
    }
}
