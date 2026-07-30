function Resolve-ToolkitGraphEnvironment {
    <#
    .SYNOPSIS
        Converts a toolkit cloud name into a Microsoft Graph environment name.
    #>

    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$CloudEnvironment = 'Global'
    )

    switch ($CloudEnvironment.Trim().ToLowerInvariant()) {
        'global'  { return 'Global' }
        'gcc'     { return 'Global' }
        'gcchigh' { return 'USGov' }
        'dod'     { return 'USGovDoD' }
        'china'   { return 'China' }

        default {
            throw "Unsupported Graph cloud environment: '$CloudEnvironment'."
        }
    }
}
