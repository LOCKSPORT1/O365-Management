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

    $CurrentUserId =
        '22222222-2222-2222-2222-222222222222'

    $RecommendedUserId =
        '33333333-3333-3333-3333-333333333333'
}

Describe 'Invoke-PrimaryUserRemediation' {
    It 'is exported by the module' {
        Get-Command `
            -Name Invoke-PrimaryUserRemediation `
            -Module PrimaryUserAudit `
            -ErrorAction Stop |
            Should -Not -BeNullOrEmpty
    }

    Context 'WhatIf behavior' {
        It 'returns WhatIf for an eligible Change action' {
            $recommendation = [pscustomobject]@{
                DeviceName =
                    'PBI-TEST-001'

                ManagedDeviceId =
                    $ManagedDeviceId

                CurrentUserId =
                    $CurrentUserId

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
                    -WhatIf

            $result.RemediationStatus |
                Should -Be 'WhatIf'

            $result.RecommendedAction |
                Should -Be 'Change'

            $result.Message |
                Should -Be 'No change was made.'
        }

        It 'returns WhatIf for an eligible Assign action' {
            $recommendation = [pscustomobject]@{
                DeviceName =
                    'PBI-TEST-002'

                ManagedDeviceId =
                    $ManagedDeviceId

                CurrentUserId =
                    ''

                CurrentUserPrincipal =
                    ''

                RecommendedUserId =
                    $RecommendedUserId

                RecommendedUserPrincipal =
                    'assigneduser@example.com'

                RecommendedAction =
                    'Assign'
            }

            $result =
                $recommendation |
                Invoke-PrimaryUserRemediation `
                    -WhatIf

            $result.RemediationStatus |
                Should -Be 'WhatIf'

            $result.RecommendedAction |
                Should -Be 'Assign'
        }
    }

    Context 'Action filtering' {
        It 'skips a NoChange action' {
            $recommendation = [pscustomobject]@{
                DeviceName =
                    'PBI-TEST-003'

                ManagedDeviceId =
                    $ManagedDeviceId

                CurrentUserId =
                    $CurrentUserId

                CurrentUserPrincipal =
                    'user@example.com'

                RecommendedUserId =
                    $CurrentUserId

                RecommendedUserPrincipal =
                    'user@example.com'

                RecommendedAction =
                    'NoChange'
            }

            $result =
                $recommendation |
                Invoke-PrimaryUserRemediation `
                    -WhatIf

            $result.RemediationStatus |
                Should -Be 'Skipped'

            $result.Message |
                Should -Be (
                    "Action 'NoChange' is not eligible for remediation."
                )
        }

        It 'skips a Review action' {
            $recommendation = [pscustomobject]@{
                DeviceName =
                    'PBI-TEST-004'

                ManagedDeviceId =
                    $ManagedDeviceId

                CurrentUserId =
                    $CurrentUserId

                CurrentUserPrincipal =
                    'user1@example.com'

                RecommendedUserId =
                    $RecommendedUserId

                RecommendedUserPrincipal =
                    'user2@example.com'

                RecommendedAction =
                    'Review'
            }

            $result =
                $recommendation |
                Invoke-PrimaryUserRemediation `
                    -WhatIf

            $result.RemediationStatus |
                Should -Be 'Skipped'
        }
    }

    Context 'Input validation' {
        It 'throws when DeviceName is missing' {
            $recommendation = [pscustomobject]@{
                DeviceName =
                    ''

                ManagedDeviceId =
                    $ManagedDeviceId

                RecommendedUserId =
                    $RecommendedUserId

                RecommendedAction =
                    'Change'
            }

            {
                $recommendation |
                    Invoke-PrimaryUserRemediation `
                        -WhatIf
            } |
                Should -Throw (
                    'Each recommendation must contain a DeviceName.'
                )
        }

        It 'throws when ManagedDeviceId is missing' {
            $recommendation = [pscustomobject]@{
                DeviceName =
                    'PBI-TEST-005'

                ManagedDeviceId =
                    ''

                RecommendedUserId =
                    $RecommendedUserId

                RecommendedAction =
                    'Change'
            }

            {
                $recommendation |
                    Invoke-PrimaryUserRemediation `
                        -WhatIf
            } |
                Should -Throw '*must contain ManagedDeviceId*'
        }

        It 'throws when RecommendedUserId is missing' {
            $recommendation = [pscustomobject]@{
                DeviceName =
                    'PBI-TEST-006'

                ManagedDeviceId =
                    $ManagedDeviceId

                RecommendedUserId =
                    ''

                RecommendedAction =
                    'Change'
            }

            {
                $recommendation |
                    Invoke-PrimaryUserRemediation `
                        -WhatIf
            } |
                Should -Throw '*must contain RecommendedUserId*'
        }
    }

    Context 'Graph execution' {
        It 'calls Set-IntunePrimaryUser for an approved action' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId =
                        $ManagedDeviceId

                    RecommendedUserId =
                        $RecommendedUserId
                } {

                Mock Set-IntunePrimaryUser {
                    [pscustomobject]@{
                        ManagedDeviceId =
                            $ManagedDeviceId

                        UserId =
                            $RecommendedUserId

                        Method =
                            'POST'

                        ExecutionStatus =
                            'Completed'
                    }
                }

                $recommendation = [pscustomobject]@{
                    DeviceName =
                        'PBI-TEST-007'

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

                $result.GraphRequest.ExecutionStatus |
                    Should -Be 'Completed'

                Should `
                    -Invoke Set-IntunePrimaryUser `
                    -Times 1 `
                    -ParameterFilter {
                        $ManagedDeviceId -eq
                            '11111111-1111-1111-1111-111111111111' -and

                        $UserId -eq
                            '33333333-3333-3333-3333-333333333333' -and

                        $Execute
                    }
            }
        }

        It 'returns Failed when the Graph helper throws' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId =
                        $ManagedDeviceId

                    RecommendedUserId =
                        $RecommendedUserId
                } {

                Mock Set-IntunePrimaryUser {
                    throw 'Simulated Graph failure.'
                }

                $recommendation = [pscustomobject]@{
                    DeviceName =
                        'PBI-TEST-008'

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
                    Should -Be 'Failed'

                $result.ErrorMessage |
                    Should -Be 'Simulated Graph failure.'
            }
        }
    }

    Context 'Pipeline processing' {
        It 'processes multiple recommendation records' {
            $recommendations = @(
                [pscustomobject]@{
                    DeviceName =
                        'PBI-TEST-009'

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

                [pscustomobject]@{
                    DeviceName =
                        'PBI-TEST-010'

                    ManagedDeviceId =
                        $ManagedDeviceId

                    CurrentUserPrincipal =
                        ''

                    RecommendedUserId =
                        $RecommendedUserId

                    RecommendedUserPrincipal =
                        'assigneduser@example.com'

                    RecommendedAction =
                        'Assign'
                }

                [pscustomobject]@{
                    DeviceName =
                        'PBI-TEST-011'

                    ManagedDeviceId =
                        $ManagedDeviceId

                    CurrentUserPrincipal =
                        'user@example.com'

                    RecommendedUserId =
                        $CurrentUserId

                    RecommendedUserPrincipal =
                        'user@example.com'

                    RecommendedAction =
                        'NoChange'
                }
            )

            $result =
                $recommendations |
                Invoke-PrimaryUserRemediation `
                    -WhatIf

            $result.Count |
                Should -Be 3

            (
                $result |
                Where-Object RemediationStatus -eq 'WhatIf'
            ).Count |
                Should -Be 2

            (
                $result |
                Where-Object RemediationStatus -eq 'Skipped'
            ).Count |
                Should -Be 1
        }
    }
}

AfterAll {
    Remove-Module `
        PrimaryUserAudit `
        -Force `
        -ErrorAction SilentlyContinue
}

