function Get-IntunePrimaryUser {
    <#
    .SYNOPSIS
        Retrieves the currently assigned Intune primary user.

    .DESCRIPTION
        Queries the users relationship for an Intune managed device and
        returns a normalized primary-user result.

    .PARAMETER ManagedDeviceId
        The Microsoft Intune managed-device GUID.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ManagedDeviceId
    )

    Set-StrictMode -Version Latest

    $parsedManagedDeviceId = [guid]::Empty

    if (
        -not [guid]::TryParse(
            $ManagedDeviceId,
            [ref]$parsedManagedDeviceId
        )
    ) {
        throw 'ManagedDeviceId must be a valid GUID.'
    }

    $uri = (
        "https://graph.microsoft.com/v1.0/" +
        "deviceManagement/managedDevices(" +
        "'$ManagedDeviceId')/users"
    )

    $response = Invoke-GraphRequestWithRetry `
        -Uri $uri `
        -Method GET

    $users = @()

    if ($null -ne $response) {
        if (
            $response.PSObject.Properties.Name -contains 'value'
        ) {
            $users = @($response.value)
        }
        else {
            $users = @($response)
        }
    }

    if ($users.Count -eq 0) {
        return [pscustomobject]@{
            ManagedDeviceId =
                $ManagedDeviceId

            AssignedUserId =
                $null

            AssignedUserPrincipal =
                $null

            AssignedUserName =
                $null

            AssignedUserCount =
                0

            QueryStatus =
                'NoUserAssigned'
        }
    }

    $assignedUser = $users[0]

    $assignedUserId =
        if (
            $assignedUser.PSObject.Properties.Name -contains 'id'
        ) {
            [string]$assignedUser.id
        }
        else {
            $null
        }

    $assignedUserPrincipal =
        if (
            $assignedUser.PSObject.Properties.Name -contains
            'userPrincipalName'
        ) {
            [string]$assignedUser.userPrincipalName
        }
        else {
            $null
        }

    $assignedUserName =
        if (
            $assignedUser.PSObject.Properties.Name -contains
            'displayName'
        ) {
            [string]$assignedUser.displayName
        }
        else {
            $null
        }

    return [pscustomobject]@{
        ManagedDeviceId =
            $ManagedDeviceId

        AssignedUserId =
            $assignedUserId

        AssignedUserPrincipal =
            $assignedUserPrincipal

        AssignedUserName =
            $assignedUserName

        AssignedUserCount =
            $users.Count

        QueryStatus =
            'Retrieved'
    }
}
