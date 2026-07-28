BeforeAll {
    Remove-Module `
        PrimaryUserAudit `
        -Force `
        -ErrorAction SilentlyContinue

    Import-Module `
        "$PSScriptRoot\..\PrimaryUserAudit.psd1" `
        -Force

    $ManagedDeviceId =
        '11111111-1111-1111-1111-111111111111'

    $RecommendedUserId =
        '33333333-3333-3333-3333-333333333333'
}

Describe 'Invoke-PrimaryUserRemediation verification' {
    Context 'Successful verification' {
        It 'returns Verified when Intune reports the expected user' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId =
                        $ManagedDeviceId

                    RecommendedUserId =
                        $RecommendedUserId
                } {

                Mock Set-IntunePrimaryUser {
                    [pscustomobject]@{
                        ExecutionStatus =
                            'Completed'

                        ManagedDeviceId =
                            $ManagedDeviceId

                        UserId =
                            $RecommendedUserId
                    }
                }

                Mock Get-IntunePrimaryUser {
                    [pscustomobject]@{
                        AssignedUserId =
                            $RecommendedUserId

                        AssignedUserPrincipal =
                            'newuser@example.com'

                        QueryStatus =
                            'Retrieved'
                    }
                }

                $recommendation =
                    [pscustomobject]@{
                        DeviceName =
                            'PBI-VERIFY-001'

                        ManagedDeviceId =
                            $ManagedDeviceId

                        CurrentUserPrincipal =
                            'olduser@example.com'

                        RecommendedUserId =
                            $RecommendedUserId

                        RecommendedUserPrincipal =
                            'newuser@example.com'

                        RecommendedAction =
                            'Change'
                    }

                $result =
                    $recommendation |
                    Invoke-PrimaryUserRemediation `
                        -Confirm:$false `
                        -VerificationDelaySeconds 0

                $result.RemediationStatus |
                    Should -Be 'Completed'

                $result.VerificationStatus |
                    Should -Be 'Verified'

                $result.VerifiedUserId |
                    Should -Be $RecommendedUserId

                $result.VerifiedUserPrincipal |
                    Should -Be 'newuser@example.com'

                Should `
                    -Invoke Get-IntunePrimaryUser `
                    -Times 1
            }
        }
    }

    Context 'Pending verification' {
        It 'returns Pending when Intune reports no assigned user' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId =
                        $ManagedDeviceId

                    RecommendedUserId =
                        $RecommendedUserId
                } {

                Mock Set-IntunePrimaryUser {
                    [pscustomobject]@{
                        ExecutionStatus =
                            'Completed'
                    }
                }

                Mock Get-IntunePrimaryUser {
                    [pscustomobject]@{
                        AssignedUserId =
                            $null

                        AssignedUserPrincipal =
                            $null

                        QueryStatus =
                            'NoUserAssigned'
                    }
                }

                $recommendation =
                    [pscustomobject]@{
                        DeviceName =
                            'PBI-VERIFY-002'

                        ManagedDeviceId =
                            $ManagedDeviceId

                        CurrentUserPrincipal =
                            ''

                        RecommendedUserId =
                            $RecommendedUserId

                        RecommendedUserPrincipal =
                            'newuser@example.com'

                        RecommendedAction =
                            'Assign'
                    }

                $result =
                    $recommendation |
                    Invoke-PrimaryUserRemediation `
                        -Confirm:$false `
                        -VerificationDelaySeconds 0

                $result.RemediationStatus |
                    Should -Be 'Completed'

                $result.VerificationStatus |
                    Should -Be 'Pending'

                $result.VerifiedUserId |
                    Should -BeNullOrEmpty
            }
        }
    }

    Context 'Verification mismatch' {
        It 'returns Mismatch when Intune reports another user' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId =
                        $ManagedDeviceId

                    RecommendedUserId =
                        $RecommendedUserId
                } {

                Mock Set-IntunePrimaryUser {
                    [pscustomobject]@{
                        ExecutionStatus =
                            'Completed'
                    }
                }

                Mock Get-IntunePrimaryUser {
                    [pscustomobject]@{
                        AssignedUserId =
                            '44444444-4444-4444-4444-444444444444'

                        AssignedUserPrincipal =
                            'differentuser@example.com'

                        QueryStatus =
                            'Retrieved'
                    }
                }

                $recommendation =
                    [pscustomobject]@{
                        DeviceName =
                            'PBI-VERIFY-003'

                        ManagedDeviceId =
                            $ManagedDeviceId

                        CurrentUserPrincipal =
                            'olduser@example.com'

                        RecommendedUserId =
                            $RecommendedUserId

                        RecommendedUserPrincipal =
                            'newuser@example.com'

                        RecommendedAction =
                            'Change'
                    }

                $result =
                    $recommendation |
                    Invoke-PrimaryUserRemediation `
                        -Confirm:$false `
                        -VerificationDelaySeconds 0

                $result.RemediationStatus |
                    Should -Be 'Completed'

                $result.VerificationStatus |
                    Should -Be 'Mismatch'

                $result.VerifiedUserId |
                    Should -Be (
                        '44444444-4444-4444-4444-444444444444'
                    )

                $result.VerifiedUserPrincipal |
                    Should -Be 'differentuser@example.com'
            }
        }
    }

    Context 'Verification request failure' {
        It 'returns VerificationFailed when verification throws' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId =
                        $ManagedDeviceId

                    RecommendedUserId =
                        $RecommendedUserId
                } {

                Mock Set-IntunePrimaryUser {
                    [pscustomobject]@{
                        ExecutionStatus =
                            'Completed'
                    }
                }

                Mock Get-IntunePrimaryUser {
                    throw 'Verification request failed.'
                }

                $recommendation =
                    [pscustomobject]@{
                        DeviceName =
                            'PBI-VERIFY-004'

                        ManagedDeviceId =
                            $ManagedDeviceId

                        CurrentUserPrincipal =
                            'olduser@example.com'

                        RecommendedUserId =
                            $RecommendedUserId

                        RecommendedUserPrincipal =
                            'newuser@example.com'

                        RecommendedAction =
                            'Change'
                    }

                $result =
                    $recommendation |
                    Invoke-PrimaryUserRemediation `
                        -Confirm:$false `
                        -VerificationDelaySeconds 0

                $result.RemediationStatus |
                    Should -Be 'Completed'

                $result.VerificationStatus |
                    Should -Be 'VerificationFailed'

                $result.VerificationMessage |
                    Should -Be 'Verification request failed.'
            }
        }
    }

    Context 'Skipped verification' {
        It 'does not query Intune when SkipVerification is supplied' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId =
                        $ManagedDeviceId

                    RecommendedUserId =
                        $RecommendedUserId
                } {

                Mock Set-IntunePrimaryUser {
                    [pscustomobject]@{
                        ExecutionStatus =
                            'Completed'
                    }
                }

                Mock Get-IntunePrimaryUser

                $recommendation =
                    [pscustomobject]@{
                        DeviceName =
                            'PBI-VERIFY-005'

                        ManagedDeviceId =
                            $ManagedDeviceId

                        CurrentUserPrincipal =
                            'olduser@example.com'

                        RecommendedUserId =
                            $RecommendedUserId

                        RecommendedUserPrincipal =
                            'newuser@example.com'

                        RecommendedAction =
                            'Change'
                    }

                $result =
                    $recommendation |
                    Invoke-PrimaryUserRemediation `
                        -Confirm:$false `
                        -SkipVerification

                $result.RemediationStatus |
                    Should -Be 'Completed'

                $result.VerificationStatus |
                    Should -Be 'NotAttempted'

                $result.VerifiedUserId |
                    Should -BeNullOrEmpty

                Should `
                    -Invoke Get-IntunePrimaryUser `
                    -Times 0
            }
        }
    }
}

AfterAll {
    Remove-Module `
        PrimaryUserAudit `
        -Force `
        -ErrorAction SilentlyContinue
}
