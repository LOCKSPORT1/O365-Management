function Invoke-PrimaryUserRollback {
    <#
    .SYNOPSIS
        Restores previous Intune primary-user assignments.

    .DESCRIPTION
        Imports a rollback JSON file created by
        Export-PrimaryUserRollbackRecord and restores the previous
        Intune primary-user assignment for each device.

        Supports WhatIf, confirmation, and post-change verification.

    .PARAMETER Path
        Path to the rollback JSON file.

    .PARAMETER SkipVerification
        Skips post-rollback verification.

    .EXAMPLE
        Invoke-PrimaryUserRollback `
            -Path '.\Rollback\PrimaryUserRollback_20260728_140000.json' `
            -Confirm:$false

    .EXAMPLE
        Invoke-PrimaryUserRollback `
            -Path '.\Rollback\PrimaryUserRollback_20260728_140000.json' `
            -WhatIf
    #>

    [CmdletBinding(
        SupportsShouldProcess = $true,
        ConfirmImpact = 'High'
    )]
    param(
        [Parameter(
            Mandatory,
            Position = 0
        )]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [switch]$SkipVerification
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $records =
        Import-PrimaryUserRollbackRecord `
            -Path $Path

    foreach ($record in @($records)) {
        $currentUserId = $null
        $currentUserPrincipal = $null
        $restoredUserId = $record.PreviousUserId
        $restoredUserPrincipal = $record.PreviousUserPrincipal
        $rollbackStatus = 'Pending'
        $verificationStatus = 'NotStarted'
        $message = $null
        $errorMessage = $null

        $targetDescription =
            if (
                [string]::IsNullOrWhiteSpace(
                    $restoredUserPrincipal
                )
            ) {
                "$($record.DeviceName) : restore to no assigned primary user"
            }
            else {
                (
                    "$($record.DeviceName) : restore " +
                    "$restoredUserPrincipal"
                )
            }

        try {
            $currentAssignment =
                Get-IntunePrimaryUser `
                    -ManagedDeviceId $record.ManagedDeviceId

            $currentUserId =
                $currentAssignment.AssignedUserId

            $currentUserPrincipal =
                $currentAssignment.AssignedUserPrincipal
        }
        catch {
            $rollbackStatus = 'Failed'
            $verificationStatus = 'NotRun'
            $message =
                'Current Intune primary-user assignment could not be retrieved.'
            $errorMessage =
                $_.Exception.Message

            [pscustomobject]@{
                DeviceName =
                    $record.DeviceName

                ManagedDeviceId =
                    $record.ManagedDeviceId

                SourcePath =
                    $record.SourcePath

                RecordNumber =
                    $record.RecordNumber

                CurrentUserId =
                    $currentUserId

                CurrentUserPrincipal =
                    $currentUserPrincipal

                RestoredUserId =
                    $restoredUserId

                RestoredUserPrincipal =
                    $restoredUserPrincipal

                RollbackStatus =
                    $rollbackStatus

                VerificationStatus =
                    $verificationStatus

                Message =
                    $message

                ErrorMessage =
                    $errorMessage
            }

            continue
        }

        if (
            -not $PSCmdlet.ShouldProcess(
                $targetDescription,
                'Restore previous Intune primary-user assignment'
            )
        ) {
            [pscustomobject]@{
                DeviceName =
                    $record.DeviceName

                ManagedDeviceId =
                    $record.ManagedDeviceId

                SourcePath =
                    $record.SourcePath

                RecordNumber =
                    $record.RecordNumber

                CurrentUserId =
                    $currentUserId

                CurrentUserPrincipal =
                    $currentUserPrincipal

                RestoredUserId =
                    $restoredUserId

                RestoredUserPrincipal =
                    $restoredUserPrincipal

                RollbackStatus =
                    'WhatIf'

                VerificationStatus =
                    'NotRun'

                Message =
                    'Rollback was not executed.'

                ErrorMessage =
                    $null
            }

            continue
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $restoredUserId
            )
        ) {
            [pscustomobject]@{
                DeviceName =
                    $record.DeviceName

                ManagedDeviceId =
                    $record.ManagedDeviceId

                SourcePath =
                    $record.SourcePath

                RecordNumber =
                    $record.RecordNumber

                CurrentUserId =
                    $currentUserId

                CurrentUserPrincipal =
                    $currentUserPrincipal

                RestoredUserId =
                    $null

                RestoredUserPrincipal =
                    $null

                RollbackStatus =
                    'ManualActionRequired'

                VerificationStatus =
                    'NotRun'

                Message =
                    (
                        'The rollback record indicates that the device ' +
                        'previously had no assigned primary user. The current ' +
                        'Set-IntunePrimaryUser helper does not support removing ' +
                        'an assignment.'
                    )

                ErrorMessage =
                    $null
            }

            continue
        }

        try {
            $null =
                Set-IntunePrimaryUser `
                    -ManagedDeviceId $record.ManagedDeviceId `
                    -UserId $restoredUserId `
                    -Execute

            $rollbackStatus = 'Completed'
            $message =
                'Previous Intune primary-user assignment was restored.'
        }
        catch {
            $rollbackStatus = 'Failed'
            $verificationStatus = 'NotRun'
            $message =
                'Rollback assignment failed.'
            $errorMessage =
                $_.Exception.Message

            [pscustomobject]@{
                DeviceName =
                    $record.DeviceName

                ManagedDeviceId =
                    $record.ManagedDeviceId

                SourcePath =
                    $record.SourcePath

                RecordNumber =
                    $record.RecordNumber

                CurrentUserId =
                    $currentUserId

                CurrentUserPrincipal =
                    $currentUserPrincipal

                RestoredUserId =
                    $restoredUserId

                RestoredUserPrincipal =
                    $restoredUserPrincipal

                RollbackStatus =
                    $rollbackStatus

                VerificationStatus =
                    $verificationStatus

                Message =
                    $message

                ErrorMessage =
                    $errorMessage
            }

            continue
        }

        if ($SkipVerification) {
            $verificationStatus = 'Skipped'
        }
        else {
            try {
                $verifiedAssignment =
                    Get-IntunePrimaryUser `
                        -ManagedDeviceId $record.ManagedDeviceId

                if (
                    $verifiedAssignment.AssignedUserId -eq
                    $restoredUserId
                ) {
                    $verificationStatus = 'Verified'
                }
                elseif (
                    [string]::IsNullOrWhiteSpace(
                        $verifiedAssignment.AssignedUserId
                    )
                ) {
                    $verificationStatus = 'Pending'
                }
                else {
                    $verificationStatus = 'Mismatch'
                }
            }
            catch {
                $verificationStatus = 'VerificationFailed'
                $errorMessage =
                    $_.Exception.Message
            }
        }

        [pscustomobject]@{
            DeviceName =
                $record.DeviceName

            ManagedDeviceId =
                $record.ManagedDeviceId

            SourcePath =
                $record.SourcePath

            RecordNumber =
                $record.RecordNumber

            CurrentUserId =
                $currentUserId

            CurrentUserPrincipal =
                $currentUserPrincipal

            RestoredUserId =
                $restoredUserId

            RestoredUserPrincipal =
                $restoredUserPrincipal

            RollbackStatus =
                $rollbackStatus

            VerificationStatus =
                $verificationStatus

            Message =
                $message

            ErrorMessage =
                $errorMessage
        }
    }
}
