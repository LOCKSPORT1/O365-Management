function Get-PrimaryUserRecommendation {
    <#
    .SYNOPSIS
        Calculates the most likely primary user for each managed device.

    .DESCRIPTION
        Compares Intune managed-device information with Entra sign-in evidence.

        The function calculates:

        - Total qualifying sign-ins
        - Most active user
        - Leading-user sign-in count
        - Dominance percentage
        - Confidence level
        - Recommended action

        By default, only interactive sign-ins are used for confidence scoring.

    .PARAMETER Devices
        Managed-device objects returned by Get-ManagedWindowsDevice.

    .PARAMETER SignInEvidence
        Sign-in objects returned by Get-DeviceSignInEvidence.

    .PARAMETER MinimumSignIns
        Minimum number of qualifying sign-ins required before recommending
        a primary-user change.

    .PARAMETER MinimumDominancePercent
        Minimum percentage of qualifying sign-ins that must belong to the
        leading user.

    .PARAMETER IncludeNonInteractive
        Includes non-interactive sign-ins in confidence calculations.

    .EXAMPLE
        Get-PrimaryUserRecommendation `
            -Devices $WindowsDevices `
            -SignInEvidence $SignInEvidence

    .EXAMPLE
        Get-PrimaryUserRecommendation `
            -Devices $WindowsDevices `
            -SignInEvidence $SignInEvidence `
            -MinimumSignIns 10 `
            -MinimumDominancePercent 75
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object[]]$Devices,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [ValidateNotNull()]
        [object[]]$SignInEvidence,

        [Parameter()]
        [ValidateRange(1, 10000)]
        [int]$MinimumSignIns = 5,

        [Parameter()]
        [ValidateRange(1, 100)]
        [double]$MinimumDominancePercent = 70,

        [Parameter()]
        [switch]$IncludeNonInteractive
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $evidenceByDevice = @{}

    foreach ($signIn in $SignInEvidence) {
        if ([string]::IsNullOrWhiteSpace($signIn.EntraDeviceId)) {
            continue
        }

        if (
            -not $IncludeNonInteractive -and
            $signIn.IsInteractive -ne $true
        ) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($signIn.UserPrincipalName)) {
            continue
        }

        $deviceId = $signIn.EntraDeviceId.ToLowerInvariant()

        if (-not $evidenceByDevice.ContainsKey($deviceId)) {
            $evidenceByDevice[$deviceId] =
                [System.Collections.Generic.List[object]]::new()
        }

        $evidenceByDevice[$deviceId].Add($signIn)
    }

    foreach ($device in $Devices) {
        $deviceEvidence = @()

        if (-not [string]::IsNullOrWhiteSpace($device.EntraDeviceId)) {
            $deviceKey = $device.EntraDeviceId.ToLowerInvariant()

            if ($evidenceByDevice.ContainsKey($deviceKey)) {
                $deviceEvidence = @($evidenceByDevice[$deviceKey])
            }
        }

        $userGroups = @(
            $deviceEvidence |
            Group-Object {
                $_.UserPrincipalName.ToLowerInvariant()
            } |
            Sort-Object Count -Descending
        )

        $totalSignIns = $deviceEvidence.Count
        $leadingUser = $null
        $leadingUserDisplayName = $null
        $leadingUserId = $null
        $leadingUserSignIns = 0
        $dominancePercent = 0
        $secondPlaceSignIns = 0

        if ($userGroups.Count -gt 0) {
            $leadingGroup = $userGroups[0]
            $leadingUserSignIns = $leadingGroup.Count

            $leadingRecord = $leadingGroup.Group |
                Sort-Object CreatedDateTime -Descending |
                Select-Object -First 1

            $leadingUser = $leadingRecord.UserPrincipalName
            $leadingUserDisplayName = $leadingRecord.UserDisplayName
            $leadingUserId = $leadingRecord.UserId

            if ($totalSignIns -gt 0) {
                $dominancePercent = [math]::Round(
                    ($leadingUserSignIns / $totalSignIns) * 100,
                    2
                )
            }

            if ($userGroups.Count -gt 1) {
                $secondPlaceSignIns = $userGroups[1].Count
            }
        }

        $currentUser = $device.CurrentUserPrincipal
        $currentUserMatches = $false

        if (
            -not [string]::IsNullOrWhiteSpace($currentUser) -and
            -not [string]::IsNullOrWhiteSpace($leadingUser)
        ) {
            $currentUserMatches =
                $currentUser.Equals(
                    $leadingUser,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
        }

        $confidence = 'None'
        $recommendedAction = 'NoEvidence'
        $reason = 'No qualifying sign-in evidence was found.'

        if ($totalSignIns -gt 0) {
            if ($totalSignIns -lt $MinimumSignIns) {
                $confidence = 'Low'
                $recommendedAction = 'Review'
                $reason = (
                    'Only {0} qualifying sign-ins were found; at least {1} are required.' -f
                    $totalSignIns,
                    $MinimumSignIns
                )
            }
            elseif ($dominancePercent -lt $MinimumDominancePercent) {
                $confidence = 'Low'
                $recommendedAction = 'Review'
                $reason = (
                    'The leading user represents {0}% of sign-ins; at least {1}% is required.' -f
                    $dominancePercent,
                    $MinimumDominancePercent
                )
            }
            elseif ($currentUserMatches) {
                $confidence = 'High'
                $recommendedAction = 'NoChange'
                $reason = 'The current Intune user matches the leading sign-in user.'
            }
            elseif ([string]::IsNullOrWhiteSpace($currentUser)) {
                $confidence = 'High'
                $recommendedAction = 'Assign'
                $reason = 'No current Intune user is assigned and the evidence meets the thresholds.'
            }
            else {
                $confidence = 'High'
                $recommendedAction = 'Change'
                $reason = 'The leading sign-in user differs from the current Intune user.'
            }
        }

        [pscustomobject]@{
            ManagedDeviceId         = $device.ManagedDeviceId
            DeviceName              = $device.DeviceName
            EntraDeviceId           = $device.EntraDeviceId
            SerialNumber            = $device.SerialNumber
            Manufacturer            = $device.Manufacturer
            Model                   = $device.Model
            ComplianceState         = $device.ComplianceState
            LastSyncDateTime        = $device.LastSyncDateTime

            CurrentUserId           = $device.CurrentUserId
            CurrentUserPrincipal    = $currentUser
            CurrentUserName         = $device.CurrentUserName

            RecommendedUserId       = $leadingUserId
            RecommendedUserPrincipal = $leadingUser
            RecommendedUserName     = $leadingUserDisplayName

            TotalSignIns            = $totalSignIns
            LeadingUserSignIns      = $leadingUserSignIns
            SecondPlaceSignIns      = $secondPlaceSignIns
            DominancePercent        = $dominancePercent

            MinimumSignIns          = $MinimumSignIns
            MinimumDominancePercent = $MinimumDominancePercent
            Confidence              = $confidence
            RecommendedAction       = $recommendedAction
            CurrentUserMatches      = $currentUserMatches
            Reason                  = $reason
        }
    }
}