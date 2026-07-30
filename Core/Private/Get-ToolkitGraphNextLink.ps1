function Get-ToolkitGraphNextLink {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Response
    )

    if ($Response -is [System.Collections.IDictionary]) {
        if ($Response.Contains('@odata.nextLink')) {
            return [string]$Response['@odata.nextLink']
        }
    }

    $nextLinkProperty = $Response.PSObject.Properties[
        '@odata.nextLink'
    ]

    if (
        $null -ne $nextLinkProperty -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$nextLinkProperty.Value
        )
    ) {
        return [string]$nextLinkProperty.Value
    }

    return $null
}
