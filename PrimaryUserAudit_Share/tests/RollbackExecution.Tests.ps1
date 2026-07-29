BeforeAll {
    Remove-Module `
        PrimaryUserAudit `
        -Force `
        -ErrorAction SilentlyContinue

    Import-Module `
        "$PSScriptRoot\..\PrimaryUserAudit.psd1" `
        -Force
}

Describe 'Invoke-PrimaryUserRollback' {
    BeforeEach {
        $script:rollbackRecord =
            [pscustomobject]@{
                SchemaVersion =
                    '1.0'

                SourcePath =
                    'C:\Temp\rollback.json'

                RecordNumber =
                    1

                DeviceName =
                    'PBI-ROLLBACK-001'

                ManagedDeviceId =
                    '11111111-1111-1111-1111-111111111111'

                PreviousUserId =
                    '22222222-2222-2222-2222-222222222222'

                PreviousUserPrincipal =
                    'olduser@example.com'

                NewUserId =
                    '33333333-3333-3333-3333-333333333333'

                NewUserPrincipal =
                    'newuser@example.com'

                RecommendedAction =
                    'Change'

                RemediationStatus =
                    'Completed'

                VerificationStatus =
                    'Verified'

                Timestamp =
                    [datetimeoffset]'2026-07-28T14:00:00-04:00'
            }

        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Import-PrimaryUserRollbackRecord `
            -MockWith {
                @($script:rollbackRecord)
            }

        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Get-IntunePrimaryUser `
            -MockWith {
                [pscustomobject]@{
                    AssignedUserId =
                        '33333333-3333-3333-3333-333333333333'

                    AssignedUserPrincipal =
                        'newuser@example.com'

                    QueryStatus =
                        'Retrieved'
                }
            }

        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Set-IntunePrimaryUser `
            -MockWith {
                [pscustomobject]@{
                    ManagedDeviceId =
                        $ManagedDeviceId

                    UserId =
                        $UserId

                    ExecutionStatus =
                        'Completed'
                }
            }
    }

    It 'is exported by the module' {
        Get-Command `
            -Module PrimaryUserAudit `
            -Name Invoke-PrimaryUserRollback |
            Should -Not -BeNullOrEmpty
    }

    It 'imports rollback records from the supplied path' {
        $result =
            Invoke-PrimaryUserRollback `
                -Path 'C:\Temp\rollback.json' `
                -Confirm:$false `
                -SkipVerification

        $result.RollbackStatus |
            Should -Be 'Completed'

        Should -Invoke `
            -ModuleName PrimaryUserAudit `
            -CommandName Import-PrimaryUserRollbackRecord `
            -Times 1 `
            -Exactly `
            -ParameterFilter {
                $Path -eq 'C:\Temp\rollback.json'
            }
    }

    It 'restores the previous user assignment' {
        $result =
            Invoke-PrimaryUserRollback `
                -Path 'C:\Temp\rollback.json' `
                -Confirm:$false `
                -SkipVerification

        $result.RestoredUserId |
            Should -Be '22222222-2222-2222-2222-222222222222'

        $result.RestoredUserPrincipal |
            Should -Be 'olduser@example.com'

        Should -Invoke `
            -ModuleName PrimaryUserAudit `
            -CommandName Set-IntunePrimaryUser `
            -Times 1 `
            -Exactly `
            -ParameterFilter {
                $ManagedDeviceId -eq
                    '11111111-1111-1111-1111-111111111111' -and
                $UserId -eq
                    '22222222-2222-2222-2222-222222222222' -and
                $Execute
            }
    }

    It 'returns WhatIf without executing the rollback' {
        $result =
            Invoke-PrimaryUserRollback `
                -Path 'C:\Temp\rollback.json' `
                -WhatIf

        $result.RollbackStatus |
            Should -Be 'WhatIf'

        $result.VerificationStatus |
            Should -Be 'NotRun'

        Should -Invoke `
            -ModuleName PrimaryUserAudit `
            -CommandName Set-IntunePrimaryUser `
            -Times 0 `
            -Exactly
    }

    It 'skips verification when requested' {
        $result =
            Invoke-PrimaryUserRollback `
                -Path 'C:\Temp\rollback.json' `
                -Confirm:$false `
                -SkipVerification

        $result.RollbackStatus |
            Should -Be 'Completed'

        $result.VerificationStatus |
            Should -Be 'Skipped'

        Should -Invoke `
            -ModuleName PrimaryUserAudit `
            -CommandName Get-IntunePrimaryUser `
            -Times 1 `
            -Exactly
    }

    It 'returns Verified when the restored assignment is confirmed' {
        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Get-IntunePrimaryUser `
            -MockWith {
                if (
                    $script:getPrimaryUserCallCount -eq 0
                ) {
                    $script:getPrimaryUserCallCount++

                    return [pscustomobject]@{
                        AssignedUserId =
                            '33333333-3333-3333-3333-333333333333'

                        AssignedUserPrincipal =
                            'newuser@example.com'
                    }
                }

                return [pscustomobject]@{
                    AssignedUserId =
                        '22222222-2222-2222-2222-222222222222'

                    AssignedUserPrincipal =
                        'olduser@example.com'
                }
            }

        $script:getPrimaryUserCallCount = 0

        $result =
            Invoke-PrimaryUserRollback `
                -Path 'C:\Temp\rollback.json' `
                -Confirm:$false

        $result.RollbackStatus |
            Should -Be 'Completed'

        $result.VerificationStatus |
            Should -Be 'Verified'

        Should -Invoke `
            -ModuleName PrimaryUserAudit `
            -CommandName Get-IntunePrimaryUser `
            -Times 2 `
            -Exactly
    }

    It 'returns Pending when verification finds no assigned user yet' {
        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Get-IntunePrimaryUser `
            -MockWith {
                if (
                    $script:getPrimaryUserCallCount -eq 0
                ) {
                    $script:getPrimaryUserCallCount++

                    return [pscustomobject]@{
                        AssignedUserId =
                            '33333333-3333-3333-3333-333333333333'

                        AssignedUserPrincipal =
                            'newuser@example.com'
                    }
                }

                return [pscustomobject]@{
                    AssignedUserId =
                        $null

                    AssignedUserPrincipal =
                        $null
                }
            }

        $script:getPrimaryUserCallCount = 0

        $result =
            Invoke-PrimaryUserRollback `
                -Path 'C:\Temp\rollback.json' `
                -Confirm:$false

        $result.VerificationStatus |
            Should -Be 'Pending'
    }

    It 'returns Mismatch when verification finds another user' {
        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Get-IntunePrimaryUser `
            -MockWith {
                if (
                    $script:getPrimaryUserCallCount -eq 0
                ) {
                    $script:getPrimaryUserCallCount++

                    return [pscustomobject]@{
                        AssignedUserId =
                            '33333333-3333-3333-3333-333333333333'

                        AssignedUserPrincipal =
                            'newuser@example.com'
                    }
                }

                return [pscustomobject]@{
                    AssignedUserId =
                        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'

                    AssignedUserPrincipal =
                        'anotheruser@example.com'
                }
            }

        $script:getPrimaryUserCallCount = 0

        $result =
            Invoke-PrimaryUserRollback `
                -Path 'C:\Temp\rollback.json' `
                -Confirm:$false

        $result.VerificationStatus |
            Should -Be 'Mismatch'
    }

    It 'returns VerificationFailed when the verification lookup throws' {
        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Get-IntunePrimaryUser `
            -MockWith {
                if (
                    $script:getPrimaryUserCallCount -eq 0
                ) {
                    $script:getPrimaryUserCallCount++

                    return [pscustomobject]@{
                        AssignedUserId =
                            '33333333-3333-3333-3333-333333333333'

                        AssignedUserPrincipal =
                            'newuser@example.com'
                    }
                }

                throw 'Verification lookup failed.'
            }

        $script:getPrimaryUserCallCount = 0

        $result =
            Invoke-PrimaryUserRollback `
                -Path 'C:\Temp\rollback.json' `
                -Confirm:$false

        $result.RollbackStatus |
            Should -Be 'Completed'

        $result.VerificationStatus |
            Should -Be 'VerificationFailed'

        $result.ErrorMessage |
            Should -BeLike '*Verification lookup failed*'
    }

    It 'returns Failed when the current assignment cannot be retrieved' {
        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Get-IntunePrimaryUser `
            -MockWith {
                throw 'Current assignment lookup failed.'
            }

        $result =
            Invoke-PrimaryUserRollback `
                -Path 'C:\Temp\rollback.json' `
                -Confirm:$false

        $result.RollbackStatus |
            Should -Be 'Failed'

        $result.VerificationStatus |
            Should -Be 'NotRun'

        $result.ErrorMessage |
            Should -BeLike '*Current assignment lookup failed*'

        Should -Invoke `
            -ModuleName PrimaryUserAudit `
            -CommandName Set-IntunePrimaryUser `
            -Times 0 `
            -Exactly
    }

    It 'returns Failed when the assignment helper throws' {
        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Set-IntunePrimaryUser `
            -MockWith {
                throw 'Graph assignment failed.'
            }

        $result =
            Invoke-PrimaryUserRollback `
                -Path 'C:\Temp\rollback.json' `
                -Confirm:$false

        $result.RollbackStatus |
            Should -Be 'Failed'

        $result.VerificationStatus |
            Should -Be 'NotRun'

        $result.ErrorMessage |
            Should -BeLike '*Graph assignment failed*'
    }

    It 'returns ManualActionRequired when the previous user was blank' {
        $script:rollbackRecord.PreviousUserId =
            $null

        $script:rollbackRecord.PreviousUserPrincipal =
            $null

        $result =
            Invoke-PrimaryUserRollback `
                -Path 'C:\Temp\rollback.json' `
                -Confirm:$false

        $result.RollbackStatus |
            Should -Be 'ManualActionRequired'

        $result.VerificationStatus |
            Should -Be 'NotRun'

        Should -Invoke `
            -ModuleName PrimaryUserAudit `
            -CommandName Set-IntunePrimaryUser `
            -Times 0 `
            -Exactly
    }

    It 'processes multiple rollback records' {
        $secondRecord =
            $script:rollbackRecord.PSObject.Copy()

        $secondRecord.RecordNumber =
            2

        $secondRecord.DeviceName =
            'PBI-ROLLBACK-002'

        $secondRecord.ManagedDeviceId =
            'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'

        $secondRecord.PreviousUserId =
            'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'

        $secondRecord.PreviousUserPrincipal =
            'second-old@example.com'

        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Import-PrimaryUserRollbackRecord `
            -MockWith {
                @(
                    $script:rollbackRecord
                    $secondRecord
                )
            }

        $results =
            Invoke-PrimaryUserRollback `
                -Path 'C:\Temp\rollback.json' `
                -Confirm:$false `
                -SkipVerification

        @($results).Count |
            Should -Be 2

        Should -Invoke `
            -ModuleName PrimaryUserAudit `
            -CommandName Set-IntunePrimaryUser `
            -Times 2 `
            -Exactly
    }
}

AfterAll {
    Remove-Module `
        PrimaryUserAudit `
        -Force `
        -ErrorAction SilentlyContinue
}
