BeforeAll {
    Remove-Module `
        PrimaryUserAudit `
        -Force `
        -ErrorAction SilentlyContinue

    Import-Module `
        "$PSScriptRoot\..\PrimaryUserAudit.psd1" `
        -Force
}

Describe 'Import-PrimaryUserRollbackRecord' {
    BeforeEach {
        $script:validRecord =
            [pscustomobject]@{
                SchemaVersion =
                    '1.0'

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
                    '2026-07-28T14:00:00-04:00'
            }

        $script:rollbackPath =
            Join-Path `
                $TestDrive `
                'rollback.json'
    }

    It 'imports a valid rollback record' {
        $script:validRecord |
            ConvertTo-Json -Depth 6 |
            Set-Content `
                -LiteralPath $script:rollbackPath `
                -Encoding utf8

        $result =
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    RollbackPath =
                        $script:rollbackPath
                } {
                    Import-PrimaryUserRollbackRecord `
                        -Path $RollbackPath
                }

        @($result).Count |
            Should -Be 1

        $result.DeviceName |
            Should -Be 'PBI-ROLLBACK-001'

        $result.ManagedDeviceId |
            Should -Be '11111111-1111-1111-1111-111111111111'

        $result.PreviousUserPrincipal |
            Should -Be 'olduser@example.com'

        $result.SchemaVersion |
            Should -Be '1.0'

        $result.RecordNumber |
            Should -Be 1
    }

    It 'imports multiple rollback records' {
        $secondRecord =
            $script:validRecord.PSObject.Copy()

        $secondRecord.DeviceName =
            'PBI-ROLLBACK-002'

        $secondRecord.ManagedDeviceId =
            'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'

        @(
            $script:validRecord
            $secondRecord
        ) |
            ConvertTo-Json -Depth 6 |
            Set-Content `
                -LiteralPath $script:rollbackPath `
                -Encoding utf8

        $result =
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    RollbackPath =
                        $script:rollbackPath
                } {
                    Import-PrimaryUserRollbackRecord `
                        -Path $RollbackPath
                }

        @($result).Count |
            Should -Be 2

        $result[1].DeviceName |
            Should -Be 'PBI-ROLLBACK-002'

        $result[1].RecordNumber |
            Should -Be 2
    }

    It 'allows a blank previous user assignment' {
        $script:validRecord.PreviousUserId =
            ''

        $script:validRecord.PreviousUserPrincipal =
            ''

        $script:validRecord |
            ConvertTo-Json -Depth 6 |
            Set-Content `
                -LiteralPath $script:rollbackPath `
                -Encoding utf8

        $result =
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    RollbackPath =
                        $script:rollbackPath
                } {
                    Import-PrimaryUserRollbackRecord `
                        -Path $RollbackPath
                }

        $result.PreviousUserId |
            Should -BeNullOrEmpty

        $result.PreviousUserPrincipal |
            Should -BeNullOrEmpty
    }

    It 'throws when the rollback file does not exist' {
        $missingPath =
            Join-Path `
                $TestDrive `
                'missing.json'

        {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    MissingPath =
                        $missingPath
                } {
                    Import-PrimaryUserRollbackRecord `
                        -Path $MissingPath
                }
        } |
            Should -Throw '*Rollback file was not found*'
    }

    It 'throws when the rollback file is empty' {
        Set-Content `
            -LiteralPath $script:rollbackPath `
            -Value '' `
            -Encoding utf8

        {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    RollbackPath =
                        $script:rollbackPath
                } {
                    Import-PrimaryUserRollbackRecord `
                        -Path $RollbackPath
                }
        } |
            Should -Throw '*Rollback file is empty*'
    }

    It 'throws when the JSON is invalid' {
        Set-Content `
            -LiteralPath $script:rollbackPath `
            -Value '{ invalid-json' `
            -Encoding utf8

        {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    RollbackPath =
                        $script:rollbackPath
                } {
                    Import-PrimaryUserRollbackRecord `
                        -Path $RollbackPath
                }
        } |
            Should -Throw '*invalid JSON*'
    }

    It 'throws when a required property is missing' {
        $script:validRecord.PSObject.Properties.Remove(
            'ManagedDeviceId'
        )

        $script:validRecord |
            ConvertTo-Json -Depth 6 |
            Set-Content `
                -LiteralPath $script:rollbackPath `
                -Encoding utf8

        {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    RollbackPath =
                        $script:rollbackPath
                } {
                    Import-PrimaryUserRollbackRecord `
                        -Path $RollbackPath
                }
        } |
            Should -Throw "*missing required property 'ManagedDeviceId'*"
    }

    It 'throws when the schema version is unsupported' {
        $script:validRecord.SchemaVersion =
            '2.0'

        $script:validRecord |
            ConvertTo-Json -Depth 6 |
            Set-Content `
                -LiteralPath $script:rollbackPath `
                -Encoding utf8

        {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    RollbackPath =
                        $script:rollbackPath
                } {
                    Import-PrimaryUserRollbackRecord `
                        -Path $RollbackPath
                }
        } |
            Should -Throw '*unsupported schema version*'
    }

    It 'throws when ManagedDeviceId is invalid' {
        $script:validRecord.ManagedDeviceId =
            'not-a-guid'

        $script:validRecord |
            ConvertTo-Json -Depth 6 |
            Set-Content `
                -LiteralPath $script:rollbackPath `
                -Encoding utf8

        {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    RollbackPath =
                        $script:rollbackPath
                } {
                    Import-PrimaryUserRollbackRecord `
                        -Path $RollbackPath
                }
        } |
            Should -Throw '*invalid ManagedDeviceId*'
    }

    It 'throws when PreviousUserId is invalid' {
        $script:validRecord.PreviousUserId =
            'not-a-guid'

        $script:validRecord |
            ConvertTo-Json -Depth 6 |
            Set-Content `
                -LiteralPath $script:rollbackPath `
                -Encoding utf8

        {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    RollbackPath =
                        $script:rollbackPath
                } {
                    Import-PrimaryUserRollbackRecord `
                        -Path $RollbackPath
                }
        } |
            Should -Throw '*invalid PreviousUserId*'
    }

    It 'throws when NewUserId is invalid' {
        $script:validRecord.NewUserId =
            'not-a-guid'

        $script:validRecord |
            ConvertTo-Json -Depth 6 |
            Set-Content `
                -LiteralPath $script:rollbackPath `
                -Encoding utf8

        {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    RollbackPath =
                        $script:rollbackPath
                } {
                    Import-PrimaryUserRollbackRecord `
                        -Path $RollbackPath
                }
        } |
            Should -Throw '*invalid NewUserId*'
    }

    It 'throws when Timestamp is invalid' {
        $script:validRecord.Timestamp =
            'not-a-date'

        $script:validRecord |
            ConvertTo-Json -Depth 6 |
            Set-Content `
                -LiteralPath $script:rollbackPath `
                -Encoding utf8

        {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    RollbackPath =
                        $script:rollbackPath
                } {
                    Import-PrimaryUserRollbackRecord `
                        -Path $RollbackPath
                }
        } |
            Should -Throw '*invalid Timestamp*'
    }
}

AfterAll {
    Remove-Module `
        PrimaryUserAudit `
        -Force `
        -ErrorAction SilentlyContinue
}
