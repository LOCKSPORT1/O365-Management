function Set-IntunePrimaryUser {
    <#
    .SYNOPSIS
        Builds or executes an Intune primary-user assignment request.

    .DESCRIPTION
        Creates the Microsoft Graph request needed to assign a primary user
        to an Intune managed Windows device.

        By default, this function only returns the planned request. No Graph
        write occurs unless the Execute switch is explicitly supplied.

    .PARAMETER ManagedDeviceId
        The Intune managed-device ID.

    .PARAMETER UserId
        The Microsoft Entra object ID of the user to assign.

    .PARAMETER Execute
        Executes the Microsoft Graph request. Without this switch, the
        function only returns a request preview.

    .EXAMPLE
        Set-IntunePrimaryUser `
            -ManagedDeviceId $ManagedDeviceId `
            -UserId $UserId

    .EXAMPLE
        Set-IntunePrimaryUser `
            -ManagedDeviceId $ManagedDeviceId `
            -UserId $UserId `
            -Execute
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ManagedDeviceId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$UserId,

        [Parameter()]
        [switch]$Execute
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (
        -not [guid]::TryParse(
            $ManagedDeviceId,
            [ref]([guid]::Empty)
        )
    ) {
        throw 'ManagedDeviceId must be a valid GUID.'
    }

    if (
        -not [guid]::TryParse(
            $UserId,
            [ref]([guid]::Empty)
        )
    ) {
        throw 'UserId must be a valid GUID.'
    }

    $uri = (
        "https://graph.microsoft.com/v1.0/" +
        "deviceManagement/managedDevices('$ManagedDeviceId')/users/`$ref"
    )

    $body = @{
        '@odata.id' = (
            "https://graph.microsoft.com/v1.0/users/$UserId"
        )
    }

    $request = [pscustomobject]@{
        ManagedDeviceId = $ManagedDeviceId
        UserId           = $UserId
        Method           = 'POST'
        Uri              = $uri
        Body             = $body
        ExecutionStatus  = 'Planned'
        GraphResponse    = $null
    }

    if (-not $Execute) {
        return $request
    }

    if (
        -not (
            Get-Command `
                -Name Invoke-GraphRequestWithRetry `
                -ErrorAction SilentlyContinue
        )
    ) {
        throw 'Invoke-GraphRequestWithRetry is not loaded.'
    }

    $response = Invoke-GraphRequestWithRetry `
        -Method POST `
        -Uri $uri `
        -Body $body `
        -DisablePagination `
        -Verbose:$VerbosePreference

    $request.ExecutionStatus = 'Completed'
    $request.GraphResponse = $response

    return $request
}
