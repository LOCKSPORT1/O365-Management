function Invoke-PrimaryUserRemediation {
    <#
    .SYNOPSIS
        Applies, verifies, and records rollback data for approved Intune
        primary-user recommendations.

    .DESCRIPTION
        Processes primary-user audit recommendation records.

        Assign and Change recommendations are eligible for remediation by
        default. Other actions are returned as skipped.

        Before an approved change is made, the function queries Intune for the
        current primary-user assignment. That previous assignment is stored in
        a rollback record. After all pipeline records are processed, the
        rollback records are exported to one JSON file.

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

    .PARAMETER RollbackOutputDirectory
        Directory where the rollback JSON file will be created.

    .PARAMETER RollbackOutputPath
        Optional complete path for the rollback JSON file. When supplied, it
        overrides RollbackOutputDirectory.

    .PARAMETER NoRollbackExport
        Disables rollback capture and export. Use this only when intentionally
        applying remediation without generating a rollback file.

    .EXAMPLE
        $Recommendations |
            Invoke-PrimaryUserRemediation -WhatIf

    .EXAMPLE
        $Recommendations |
            Invoke-PrimaryUserRemediation `
                -Confirm:$false `
                -RollbackOutputDirectory '.\Rollback'

    .EXAMPLE
        $Recommendations |
            Invoke-PrimaryUserRemediation `
                -Confirm:$false `
                -RollbackOutputPath '.\Rollback\change-set.json'
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
        [switch]$SkipVerification,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$RollbackOutputDirectory =
            (Join-Path $PWD 'Rollback'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$RollbackOutputPath,

        [Parameter()]
        [switch]$NoRollbackExport
    )

    begin {
        Set-StrictMode -Version Latest

        $results =
            [System.Collections.Generic.List[object]]::new()

        $rollbackRecords =
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
                throw 'Each recommendation must contain a DeviceName.'
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

                        RollbackExportStatus =
                            'NotCreated'

                        RollbackOutputPath =
                            $null

                        RollbackExportError =
                            $null
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

                        RollbackExportStatus =
                            'NotCreated'

                        RollbackOutputPath =
                            $null

                        RollbackExportError =
                            $null
                    }
                )

                continue
            }

            $previousUserId =
                ''

            $previousUserPrincipal =
                ''

            if (-not $NoRollbackExport) {
                try {
                    $previousAssignment =
                        Get-IntunePrimaryUser `
                            -ManagedDeviceId $managedDeviceId

                    $previousUserId =
                        [string]$previousAssignment.AssignedUserId

                    $previousUserPrincipal =
                        [string]$previousAssignment.AssignedUserPrincipal
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
                                (
                                    'Rollback state could not be captured. ' +
                                    'No change was made.'
                                )

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
                                    'remediation did not start.'
                                )

                            RollbackExportStatus =
                                'NotCreated'

                            RollbackOutputPath =
                                $null

                            RollbackExportError =
                                $_.Exception.Message
                        }
                    )

                    continue
                }
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

                $result =
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

                        RollbackExportStatus =
                            if ($NoRollbackExport) {
                                'Disabled'
                            }
                            else {
                                'Pending'
                            }

                        RollbackOutputPath =
                            $null

                        RollbackExportError =
                            $null
                    }

                $results.Add($result)

                if (-not $NoRollbackExport) {
                    $rollbackRecords.Add(
                        [pscustomobject]@{
                            DeviceName =
                                $deviceName

                            ManagedDeviceId =
                                $managedDeviceId

                            PreviousUserId =
                                $previousUserId

                            PreviousUserPrincipal =
                                $previousUserPrincipal

                            NewUserId =
                                $recommendedUserId

                            NewUserPrincipal =
                                $recommendedUserPrincipal

                            RecommendedAction =
                                $action

                            RemediationStatus =
                                'Completed'

                            VerificationStatus =
                                $verificationStatus

                            Timestamp =
                                [datetimeoffset]::Now
                        }
                    )
                }
            }
            catch {
                $result =
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

                        RollbackExportStatus =
                            if ($NoRollbackExport) {
                                'Disabled'
                            }
                            else {
                                'Pending'
                            }

                        RollbackOutputPath =
                            $null

                        RollbackExportError =
                            $null
                    }

                $results.Add($result)

                if (-not $NoRollbackExport) {
                    $rollbackRecords.Add(
                        [pscustomobject]@{
                            DeviceName =
                                $deviceName

                            ManagedDeviceId =
                                $managedDeviceId

                            PreviousUserId =
                                $previousUserId

                            PreviousUserPrincipal =
                                $previousUserPrincipal

                            NewUserId =
                                $recommendedUserId

                            NewUserPrincipal =
                                $recommendedUserPrincipal

                            RecommendedAction =
                                $action

                            RemediationStatus =
                                'Failed'

                            VerificationStatus =
                                'NotAttempted'

                            Timestamp =
                                [datetimeoffset]::Now
                        }
                    )
                }
            }
        }
    }

    end {
        if (
            -not $NoRollbackExport -and
            $rollbackRecords.Count -gt 0
        ) {
            try {
                $exportParameters = @{
                    Record =
                        @($rollbackRecords)
                }

                if (
                    -not [string]::IsNullOrWhiteSpace(
                        $RollbackOutputPath
                    )
                ) {
                    $exportParameters.OutputPath =
                        $RollbackOutputPath
                }
                else {
                    $exportParameters.OutputDirectory =
                        $RollbackOutputDirectory
                }

                $rollbackExport =
                    Export-PrimaryUserRollbackRecord `
                        @exportParameters

                foreach ($result in $results) {
                    if (
                        $result.RollbackExportStatus -eq
                        'Pending'
                    ) {
                        $result.RollbackExportStatus =
                            'Completed'

                        $result.RollbackOutputPath =
                            $rollbackExport.OutputPath
                    }
                }
            }
            catch {
                foreach ($result in $results) {
                    if (
                        $result.RollbackExportStatus -eq
                        'Pending'
                    ) {
                        $result.RollbackExportStatus =
                            'Failed'

                        $result.RollbackExportError =
                            $_.Exception.Message
                    }
                }
            }
        }

        return $results
    }
}
