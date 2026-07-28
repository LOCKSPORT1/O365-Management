function Invoke-PrimaryUserRemediation {
    <#
    .SYNOPSIS
        Applies and verifies approved Intune primary-user recommendations.

    .DESCRIPTION
        Processes primary-user audit recommendation records.

        Assign and Change recommendations are eligible for remediation by
        default. Other actions are returned as skipped.

        The function supports PowerShell ShouldProcess, including WhatIf and
        Confirm. After a successful Microsoft Graph assignment request, the
        function can query Intune again and verify the resulting primary user.

    .PARAMETER Recommendation
        One or more recommendation objects produced by the primary-user audit.

    .PARAMETER AllowedAction
        Recommendation actions that may be remediated.

    .PARAMETER VerificationDelaySeconds
        Number of seconds to wait before querying Intune to verify the change.

    .PARAMETER SkipVerification
        Completes remediation without querying Intune afterward.

    .EXAMPLE
        $Recommendations |
            Invoke-PrimaryUserRemediation -WhatIf

    .EXAMPLE
        $Recommendations |
            Invoke-PrimaryUserRemediation -Confirm:$false

    .EXAMPLE
        $Recommendations |
            Invoke-PrimaryUserRemediation `
                -Confirm:$false `
                -VerificationDelaySeconds 10

    .EXAMPLE
        $Recommendations |
            Invoke-PrimaryUserRemediation `
                -Confirm:$false `
                -SkipVerification
    #>

    [CmdletBinding(
        SupportsShouldProcess = $true,
        ConfirmImpact = 'High'
    )]
    param(
        [Parameter(
            Mandatory,
            ValueFromPipeline
        )]
        [ValidateNotNullOrEmpty()]
        [object[]]$Recommendation,

        [Parameter()]
        [ValidateSet(
            'Assign',
            'Change'
        )]
        [string[]]$AllowedAction = @(
            'Assign',
            'Change'
        ),

        [Parameter()]
        [ValidateRange(0, 300)]
        [int]$VerificationDelaySeconds = 5,

        [Parameter()]
        [switch]$SkipVerification
    )

    begin {
        Set-StrictMode -Version Latest

        $results =
            [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $Recommendation) {
            $deviceName =
                if (
                    $item.PSObject.Properties.Name -contains
                    'DeviceName'
                ) {
                    [string]$item.DeviceName
                }
                else {
                    ''
                }

            $managedDeviceId =
                if (
                    $item.PSObject.Properties.Name -contains
                    'ManagedDeviceId'
                ) {
                    [string]$item.ManagedDeviceId
                }
                else {
                    ''
                }

            $action =
                if (
                    $item.PSObject.Properties.Name -contains
                    'RecommendedAction'
                ) {
                    [string]$item.RecommendedAction
                }
                else {
                    ''
                }

            $currentUserPrincipal =
                if (
                    $item.PSObject.Properties.Name -contains
                    'CurrentUserPrincipal'
                ) {
                    [string]$item.CurrentUserPrincipal
                }
                elseif (
                    $item.PSObject.Properties.Name -contains
                    'CurrentPrimaryUser'
                ) {
                    [string]$item.CurrentPrimaryUser
                }
                else {
                    ''
                }

            $recommendedUserPrincipal =
                if (
                    $item.PSObject.Properties.Name -contains
                    'RecommendedUserPrincipal'
                ) {
                    [string]$item.RecommendedUserPrincipal
                }
                elseif (
                    $item.PSObject.Properties.Name -contains
                    'RecommendedPrimaryUser'
                ) {
                    [string]$item.RecommendedPrimaryUser
                }
                else {
                    ''
                }

            $recommendedUserId =
                if (
                    $item.PSObject.Properties.Name -contains
                    'RecommendedUserId'
                ) {
                    [string]$item.RecommendedUserId
                }
                else {
                    ''
                }

            if (
                [string]::IsNullOrWhiteSpace(
                    $deviceName
                )
            ) {
                throw (
                    'Each recommendation must contain a DeviceName.'
                )
            }

            if ($action -notin $AllowedAction) {
                $results.Add(
                    [pscustomobject]@{
                        DeviceName =
                            $deviceName

                        ManagedDeviceId =
                            $managedDeviceId

                        CurrentUserPrincipal =
                            $currentUserPrincipal

                        RecommendedUserPrincipal =
                            $recommendedUserPrincipal

                        RecommendedUserId =
                            $recommendedUserId

                        RecommendedAction =
                            $action

                        RemediationStatus =
                            'Skipped'

                        Message =
                            "Action '$action' is not eligible for remediation."

                        GraphRequest =
                            $null

                        ErrorMessage =
                            $null

                        VerificationStatus =
                            'NotAttempted'

                        VerifiedUserId =
                            $null

                        VerifiedUserPrincipal =
                            $null

                        VerificationMessage =
                            'Verification was not attempted.'
                    }
                )

                continue
            }

            if (
                [string]::IsNullOrWhiteSpace(
                    $managedDeviceId
                )
            ) {
                throw (
                    "Recommendation for device '$deviceName' " +
                    'must contain ManagedDeviceId.'
                )
            }

            $parsedManagedDeviceId =
                [guid]::Empty

            if (
                -not [guid]::TryParse(
                    $managedDeviceId,
                    [ref]$parsedManagedDeviceId
                )
            ) {
                throw (
                    "ManagedDeviceId for device '$deviceName' " +
                    'must be a valid GUID.'
                )
            }

            if (
                [string]::IsNullOrWhiteSpace(
                    $recommendedUserId
                )
            ) {
                throw (
                    "Recommendation for device '$deviceName' " +
                    'must contain RecommendedUserId.'
                )
            }

            $parsedRecommendedUserId =
                [guid]::Empty

            if (
                -not [guid]::TryParse(
                    $recommendedUserId,
                    [ref]$parsedRecommendedUserId
                )
            ) {
                throw (
                    "RecommendedUserId for device '$deviceName' " +
                    'must be a valid GUID.'
                )
            }

            $target =
                (
                    "$deviceName : " +
                    "$currentUserPrincipal -> " +
                    $recommendedUserPrincipal
                )

            $operation =
                "Apply Intune Primary User action '$action'"

            if (
                -not $PSCmdlet.ShouldProcess(
                    $target,
                    $operation
                )
            ) {
                $results.Add(
                    [pscustomobject]@{
                        DeviceName =
                            $deviceName

                        ManagedDeviceId =
                            $managedDeviceId

                        CurrentUserPrincipal =
                            $currentUserPrincipal

                        RecommendedUserPrincipal =
                            $recommendedUserPrincipal

                        RecommendedUserId =
                            $recommendedUserId

                        RecommendedAction =
                            $action

                        RemediationStatus =
                            'WhatIf'

                        Message =
                            'No change was made.'

                        GraphRequest =
                            $null

                        ErrorMessage =
                            $null

                        VerificationStatus =
                            'NotAttempted'

                        VerifiedUserId =
                            $null

                        VerifiedUserPrincipal =
                            $null

                        VerificationMessage =
                            'Verification was not attempted.'
                    }
                )

                continue
            }

            try {
                $graphRequest =
                    Set-IntunePrimaryUser `
                        -ManagedDeviceId $managedDeviceId `
                        -UserId $recommendedUserId `
                        -Execute `
                        -Verbose:$VerbosePreference

                $verificationStatus =
                    'NotAttempted'

                $verifiedUserId =
                    $null

                $verifiedUserPrincipal =
                    $null

                $verificationMessage =
                    'Verification was not attempted.'

                if (-not $SkipVerification) {
                    if ($VerificationDelaySeconds -gt 0) {
                        Start-Sleep `
                            -Seconds $VerificationDelaySeconds
                    }

                    try {
                        $verification =
                            Get-IntunePrimaryUser `
                                -ManagedDeviceId $managedDeviceId

                        $verifiedUserId =
                            [string]$verification.AssignedUserId

                        $verifiedUserPrincipal =
                            [string]$verification.AssignedUserPrincipal

                        if (
                            [string]::IsNullOrWhiteSpace(
                                $verifiedUserId
                            )
                        ) {
                            $verificationStatus =
                                'Pending'

                            $verificationMessage =
                                (
                                    'Intune did not yet return an ' +
                                    'assigned primary user.'
                                )
                        }
                        elseif (
                            $verifiedUserId -eq
                            $recommendedUserId
                        ) {
                            $verificationStatus =
                                'Verified'

                            $verificationMessage =
                                (
                                    'The assigned Intune primary user ' +
                                    'matches the recommendation.'
                                )
                        }
                        else {
                            $verificationStatus =
                                'Mismatch'

                            $verificationMessage =
                                (
                                    'Intune returned a different primary ' +
                                    'user than expected.'
                                )
                        }
                    }
                    catch {
                        $verificationStatus =
                            'VerificationFailed'

                        $verificationMessage =
                            $_.Exception.Message
                    }
                }

                $results.Add(
                    [pscustomobject]@{
                        DeviceName =
                            $deviceName

                        ManagedDeviceId =
                            $managedDeviceId

                        CurrentUserPrincipal =
                            $currentUserPrincipal

                        RecommendedUserPrincipal =
                            $recommendedUserPrincipal

                        RecommendedUserId =
                            $recommendedUserId

                        RecommendedAction =
                            $action

                        RemediationStatus =
                            'Completed'

                        Message =
                            (
                                'Intune primary user assignment ' +
                                'request completed.'
                            )

                        GraphRequest =
                            $graphRequest

                        ErrorMessage =
                            $null

                        VerificationStatus =
                            $verificationStatus

                        VerifiedUserId =
                            $verifiedUserId

                        VerifiedUserPrincipal =
                            $verifiedUserPrincipal

                        VerificationMessage =
                            $verificationMessage
                    }
                )
            }
            catch {
                $results.Add(
                    [pscustomobject]@{
                        DeviceName =
                            $deviceName

                        ManagedDeviceId =
                            $managedDeviceId

                        CurrentUserPrincipal =
                            $currentUserPrincipal

                        RecommendedUserPrincipal =
                            $recommendedUserPrincipal

                        RecommendedUserId =
                            $recommendedUserId

                        RecommendedAction =
                            $action

                        RemediationStatus =
                            'Failed'

                        Message =
                            'Intune primary user assignment failed.'

                        GraphRequest =
                            $null

                        ErrorMessage =
                            $_.Exception.Message

                        VerificationStatus =
                            'NotAttempted'

                        VerifiedUserId =
                            $null

                        VerifiedUserPrincipal =
                            $null

                        VerificationMessage =
                            (
                                'Verification was not attempted because ' +
                                'remediation failed.'
                            )
                    }
                )
            }
        }
    }

    end {
        return $results
    }
}
