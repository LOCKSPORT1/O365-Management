function Get-ManagedWindowsDevice {
    <#
    .SYNOPSIS
        Retrieves Windows devices managed by Microsoft Intune.

    .DESCRIPTION
        Queries the Microsoft Graph managedDevices endpoint and returns
        Windows devices required by the Primary User Audit tool.

        Disabled or stale-device filtering will be handled later by the
        public audit command.

    .PARAMETER IncludeNonCompliant
        Includes devices that are not currently compliant.

    .PARAMETER IncludeRetired
        Includes devices whose management state is retired.

    .EXAMPLE
        Get-ManagedWindowsDevice

    .EXAMPLE
        Get-ManagedWindowsDevice -IncludeNonCompliant
    #>

    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeNonCompliant,

        [Parameter()]
        [switch]$IncludeRetired
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not (Get-Command Invoke-GraphRequestWithRetry -ErrorAction SilentlyContinue)) {
        throw 'Invoke-GraphRequestWithRetry is not loaded.'
    }

    $selectedProperties = @(
        'id'
        'deviceName'
        'azureADDeviceId'
        'operatingSystem'
        'osVersion'
        'complianceState'
        'managementState'
        'managedDeviceOwnerType'
        'userId'
        'userPrincipalName'
        'userDisplayName'
        'enrolledDateTime'
        'lastSyncDateTime'
        'serialNumber'
        'manufacturer'
        'model'
    )

    $selectQuery = $selectedProperties -join ','

    $uri = (
        'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices' +
        '?$select=' +
        $selectQuery
    )

    Write-Verbose 'Retrieving managed devices from Microsoft Intune.'

    $response = Invoke-GraphRequestWithRetry `
        -Method GET `
        -Uri $uri `
        -Verbose:$VerbosePreference

    $devices = @()

    if ($response.value) {
        $devices = @($response.value)
    }
    elseif ($response) {
        $devices = @($response)
    }

    $devices = @(
        $devices |
        Where-Object {
            $_.operatingSystem -eq 'Windows'
        }
    )

    if (-not $IncludeNonCompliant) {
        $devices = @(
            $devices |
            Where-Object {
                $_.complianceState -ne 'noncompliant'
            }
        )
    }

    if (-not $IncludeRetired) {
        $devices = @(
            $devices |
            Where-Object {
                $_.managementState -ne 'retired'
            }
        )
    }

    $devices |
        Sort-Object deviceName |
        ForEach-Object {
            [pscustomobject]@{
                ManagedDeviceId       = $_.id
                DeviceName            = $_.deviceName
                EntraDeviceId         = $_.azureADDeviceId
                OperatingSystem       = $_.operatingSystem
                OSVersion             = $_.osVersion
                ComplianceState       = $_.complianceState
                ManagementState       = $_.managementState
                Ownership             = $_.managedDeviceOwnerType
                CurrentUserId         = $_.userId
                CurrentUserPrincipal  = $_.userPrincipalName
                CurrentUserName       = $_.userDisplayName
                EnrolledDateTime      = $_.enrolledDateTime
                LastSyncDateTime      = $_.lastSyncDateTime
                SerialNumber          = $_.serialNumber
                Manufacturer          = $_.manufacturer
                Model                 = $_.model
            }
        }
}