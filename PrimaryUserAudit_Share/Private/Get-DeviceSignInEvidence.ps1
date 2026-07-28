function Get-DeviceSignInEvidence {
    <#
    .SYNOPSIS
        Retrieves Entra sign-in evidence associated with managed devices.

    .DESCRIPTION
        Retrieves Microsoft Entra sign-in records for a specified lookback
        period and returns normalized evidence that can be matched to Intune
        managed devices using the Entra device ID.

        By default, failed sign-ins and records without a device ID are removed.

    .PARAMETER Days
        Number of days of sign-in history to retrieve.

    .PARAMETER IncludeFailed
        Includes unsuccessful sign-in events.

    .PARAMETER IncludeMissingDeviceId
        Includes sign-in records that do not contain a device ID.

    .PARAMETER DeviceIds
        Optional collection of Entra device IDs. When provided, only sign-ins
        associated with those devices are returned.

    .EXAMPLE
        Get-DeviceSignInEvidence -Days 30

    .EXAMPLE
        Get-DeviceSignInEvidence `
            -Days 14 `
            -DeviceIds $WindowsDevices.EntraDeviceId

    .EXAMPLE
        Get-DeviceSignInEvidence -Days 30 -IncludeFailed
    #>

    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 365)]
        [int]$Days = 30,

        [Parameter()]
        [switch]$IncludeFailed,

        [Parameter()]
        [switch]$IncludeMissingDeviceId,

        [Parameter()]
        [string[]]$DeviceIds
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (
        -not (
            Get-Command `
                -Name Invoke-GraphRequestWithRetry `
                -ErrorAction SilentlyContinue
        )
    ) {
        throw 'Invoke-GraphRequestWithRetry is not loaded.'
    }

    $startDateUtc = [datetime]::UtcNow.AddDays(-$Days)

    $startDateText = $startDateUtc.ToString(
        'yyyy-MM-ddTHH:mm:ssZ',
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    $selectedProperties = @(
        'id'
        'createdDateTime'
        'userId'
        'userDisplayName'
        'userPrincipalName'
        'appDisplayName'
        'resourceDisplayName'
        'clientAppUsed'
        'ipAddress'
        'isInteractive'
        'deviceDetail'
        'status'
    )

    $selectQuery = $selectedProperties -join ','

    $filterQuery = "createdDateTime ge $startDateText"

    $encodedFilter = [System.Uri]::EscapeDataString($filterQuery)
    $encodedSelect = [System.Uri]::EscapeDataString($selectQuery)

    $uri = (
        'https://graph.microsoft.com/v1.0/auditLogs/signIns' +
        '?$top=1000' +
        '&$select=' + $encodedSelect +
        '&$filter=' + $encodedFilter
    )

    Write-Verbose (
        'Retrieving Entra sign-ins beginning {0}.' -f
        $startDateText
    )

    $response = Invoke-GraphRequestWithRetry `
        -Method GET `
        -Uri $uri `
        -Verbose:$VerbosePreference

    $signIns = @()

    if (
        $null -ne $response -and
        $response.PSObject.Properties.Name -contains 'value'
    ) {
        $signIns = @($response.value)
    }
    elseif ($null -ne $response) {
        $signIns = @($response)
    }

    Write-Verbose (
        'Microsoft Graph returned {0} sign-in records.' -f
        $signIns.Count
    )

    $normalizedDeviceIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($deviceId in @($DeviceIds)) {
        if (-not [string]::IsNullOrWhiteSpace($deviceId)) {
            $null = $normalizedDeviceIds.Add($deviceId.Trim())
        }
    }

    foreach ($signIn in $signIns) {
        $deviceId = $null
        $deviceName = $null
        $operatingSystem = $null
        $browser = $null
        $isManaged = $null
        $isCompliant = $null
        $trustType = $null
        $errorCode = $null
        $failureReason = $null

        if ($null -ne $signIn.deviceDetail) {
            $deviceId = $signIn.deviceDetail.deviceId
            $deviceName = $signIn.deviceDetail.displayName
            $operatingSystem = $signIn.deviceDetail.operatingSystem
            $browser = $signIn.deviceDetail.browser
            $isManaged = $signIn.deviceDetail.isManaged
            $isCompliant = $signIn.deviceDetail.isCompliant
            $trustType = $signIn.deviceDetail.trustType
        }

        if ($null -ne $signIn.status) {
            $errorCode = $signIn.status.errorCode
            $failureReason = $signIn.status.failureReason
        }

        if (
            -not $IncludeMissingDeviceId -and
            [string]::IsNullOrWhiteSpace($deviceId)
        ) {
            continue
        }

        if (
            -not $IncludeFailed -and
            $null -ne $errorCode -and
            [int]$errorCode -ne 0
        ) {
            continue
        }

        if (
            $normalizedDeviceIds.Count -gt 0 -and
            -not [string]::IsNullOrWhiteSpace($deviceId) -and
            -not $normalizedDeviceIds.Contains($deviceId)
        ) {
            continue
        }

        [pscustomobject]@{
            SignInId             = $signIn.id
            CreatedDateTime      = [datetime]$signIn.createdDateTime
            UserId               = $signIn.userId
            UserDisplayName      = $signIn.userDisplayName
            UserPrincipalName    = $signIn.userPrincipalName
            EntraDeviceId        = $deviceId
            DeviceDisplayName    = $deviceName
            OperatingSystem      = $operatingSystem
            Browser              = $browser
            IsManaged            = $isManaged
            IsCompliant          = $isCompliant
            TrustType            = $trustType
            IsInteractive        = $signIn.isInteractive
            Application          = $signIn.appDisplayName
            Resource             = $signIn.resourceDisplayName
            ClientApplication    = $signIn.clientAppUsed
            IPAddress            = $signIn.ipAddress
            ErrorCode            = $errorCode
            FailureReason        = $failureReason
        }
    }
}