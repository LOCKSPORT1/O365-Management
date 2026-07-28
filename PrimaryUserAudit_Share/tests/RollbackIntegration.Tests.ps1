BeforeAll {
    $modulePath =
        Join-Path `
            $PSScriptRoot `
            '..\PrimaryUserAudit.psd1'

    Import-Module `
        $modulePath `
        -Force
}

Describe 'Invoke-PrimaryUserRemediation rollback integration' {
    BeforeEach {
        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Set-IntunePrimaryUser `
            -MockWith {
                [pscustomobject]@{
                    Method = 'POST'
                    Status = 'Completed'
                }
            }

        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Get-IntunePrimaryUser `
            -MockWith {
                [pscustomobject]@{
                    AssignedUserId =
                        '11111111-1111-1111-1111-111111111111'

                    AssignedUserPrincipal =
                        'olduser@example.com'
                }
            }

        Mock `
            -ModuleName PrimaryUserAudit `
            -CommandName Export-PrimaryUserRollbackRecord `
            -MockWith {
                [pscustomobject]@{
                    OutputPath =
                        'C:\Temp\PrimaryUserRollback_test.json'

                    RecordCount =
                        @($Record).Count

                    ExportStatus =
                        'Completed'
                }
            }

        $script:recommendation =
            [pscustomobject]@{
                DeviceName =
                    'PBI-ROLLBACK-001'

                ManagedDeviceId =
                    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'

                CurrentUserPrincipal =
                    'olduser@example.com'

                RecommendedUserPrincipal =
                    'newuser@example.com'

                RecommendedUserId =
                    '22222222-2222-2222-2222-222222222222'

                RecommendedAction =
                    'Change'
            }
    }

    Context 'Rollback capture before remediation' {
        It 'captures the current Intune primary user before making the change' {
            $result =
                $script:recommendation |
                    Invoke-PrimaryUserRemediation `
                        -Confirm:$false `
                        -SkipVerification

            $result.RemediationStatus |
                Should -Be 'Completed'

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Get-IntunePrimaryUser `
                -Times 1 `
                -Exactly

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Set-IntunePrimaryUser `
                -Times 1 `
                -Exactly
        }

        It 'exports the previous and new primary-user values' {
            $null =
                $script:recommendation |
                    Invoke-PrimaryUserRemediation `
                        -Confirm:$false `
                        -SkipVerification

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Export-PrimaryUserRollbackRecord `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    @($Record).Count -eq 1 -and
                    $Record[0].DeviceName -eq
                        'PBI-ROLLBACK-001' -and
                    $Record[0].PreviousUserId -eq
                        '11111111-1111-1111-1111-111111111111' -and
                    $Record[0].PreviousUserPrincipal -eq
                        'olduser@example.com' -and
                    $Record[0].NewUserId -eq
                        '22222222-2222-2222-2222-222222222222' -and
                    $Record[0].NewUserPrincipal -eq
                        'newuser@example.com'
                }
        }

        It 'returns the completed rollback export status and path' {
            $result =
                $script:recommendation |
                    Invoke-PrimaryUserRemediation `
                        -Confirm:$false `
                        -SkipVerification

            $result.RollbackExportStatus |
                Should -Be 'Completed'

            $result.RollbackOutputPath |
                Should -Be 'C:\Temp\PrimaryUserRollback_test.json'

            $result.RollbackExportError |
                Should -BeNullOrEmpty
        }
    }

    Context 'Rollback safety behavior' {
        It 'does not remediate when the previous assignment cannot be captured' {
            Mock `
                -ModuleName PrimaryUserAudit `
                -CommandName Get-IntunePrimaryUser `
                -MockWith {
                    throw 'Unable to retrieve the current primary user.'
                }

            $result =
                $script:recommendation |
                    Invoke-PrimaryUserRemediation `
                        -Confirm:$false `
                        -SkipVerification

            $result.RemediationStatus |
                Should -Be 'Failed'

            $result.Message |
                Should -BeLike '*Rollback state could not be captured*'

            $result.ErrorMessage |
                Should -BeLike '*Unable to retrieve*'

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Set-IntunePrimaryUser `
                -Times 0 `
                -Exactly

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Export-PrimaryUserRollbackRecord `
                -Times 0 `
                -Exactly
        }

        It 'does not capture or export rollback data during WhatIf' {
            $result =
                $script:recommendation |
                    Invoke-PrimaryUserRemediation `
                        -WhatIf

            $result.RemediationStatus |
                Should -Be 'WhatIf'

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Get-IntunePrimaryUser `
                -Times 0 `
                -Exactly

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Set-IntunePrimaryUser `
                -Times 0 `
                -Exactly

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Export-PrimaryUserRollbackRecord `
                -Times 0 `
                -Exactly
        }

        It 'allows rollback capture and export to be disabled explicitly' {
            $result =
                $script:recommendation |
                    Invoke-PrimaryUserRemediation `
                        -Confirm:$false `
                        -SkipVerification `
                        -NoRollbackExport

            $result.RemediationStatus |
                Should -Be 'Completed'

            $result.RollbackExportStatus |
                Should -Be 'Disabled'

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Get-IntunePrimaryUser `
                -Times 0 `
                -Exactly

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Set-IntunePrimaryUser `
                -Times 1 `
                -Exactly

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Export-PrimaryUserRollbackRecord `
                -Times 0 `
                -Exactly
        }
    }

    Context 'Multiple recommendation records' {
        It 'exports all rollback records in one file' {
            $recommendations =
                @(
                    $script:recommendation

                    [pscustomobject]@{
                        DeviceName =
                            'PBI-ROLLBACK-002'

                        ManagedDeviceId =
                            'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'

                        CurrentUserPrincipal =
                            'second-old@example.com'

                        RecommendedUserPrincipal =
                            'second-new@example.com'

                        RecommendedUserId =
                            '33333333-3333-3333-3333-333333333333'

                        RecommendedAction =
                            'Change'
                    }
                )

            $results =
                $recommendations |
                    Invoke-PrimaryUserRemediation `
                        -Confirm:$false `
                        -SkipVerification

            @($results).Count |
                Should -Be 2

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Set-IntunePrimaryUser `
                -Times 2 `
                -Exactly

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Export-PrimaryUserRollbackRecord `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    @($Record).Count -eq 2
                }
        }
    }

    Context 'Rollback export failure' {
        It 'reports the export failure without changing the remediation result' {
            Mock `
                -ModuleName PrimaryUserAudit `
                -CommandName Export-PrimaryUserRollbackRecord `
                -MockWith {
                    throw 'Unable to write rollback file.'
                }

            $result =
                $script:recommendation |
                    Invoke-PrimaryUserRemediation `
                        -Confirm:$false `
                        -SkipVerification

            $result.RemediationStatus |
                Should -Be 'Completed'

            $result.RollbackExportStatus |
                Should -Be 'Failed'

            $result.RollbackExportError |
                Should -BeLike '*Unable to write rollback file*'

            Should -Invoke `
                -ModuleName PrimaryUserAudit `
                -CommandName Set-IntunePrimaryUser `
                -Times 1 `
                -Exactly
        }
    }
}
