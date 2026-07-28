BeforeAll {
    Remove-Module `
        PrimaryUserAudit `
        -Force `
        -ErrorAction SilentlyContinue

    Import-Module `
        "$PSScriptRoot\..\PrimaryUserAudit.psd1" `
        -Force
}

Describe 'Export-PrimaryUserRollbackRecord' {
    BeforeEach {
        $TestOutputDirectory =
            Join-Path `
                $TestDrive `
                'Rollback'

        $RollbackRecord =
            [pscustomobject]@{
                DeviceName =
                    'PBI-TEST-001'

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
    }

    It 'creates a rollback JSON file' {
        InModuleScope PrimaryUserAudit `
            -Parameters @{
                RollbackRecord =
                    $RollbackRecord

                TestOutputDirectory =
                    $TestOutputDirectory
            } {

            $result =
                Export-PrimaryUserRollbackRecord `
                    -Record $RollbackRecord `
                    -OutputDirectory $TestOutputDirectory

            Test-Path `
                -LiteralPath $result.OutputPath |
                Should -BeTrue

            $result.RecordCount |
                Should -Be 1

            $result.ExportStatus |
                Should -Be 'Completed'
        }
    }

    It 'preserves the rollback record values' {
        InModuleScope PrimaryUserAudit `
            -Parameters @{
                RollbackRecord =
                    $RollbackRecord

                TestOutputDirectory =
                    $TestOutputDirectory
            } {

            $result =
                Export-PrimaryUserRollbackRecord `
                    -Record $RollbackRecord `
                    -OutputDirectory $TestOutputDirectory

            $content =
                Get-Content `
                    -LiteralPath $result.OutputPath `
                    -Raw |
                ConvertFrom-Json

            $content.DeviceName |
                Should -Be 'PBI-TEST-001'

            $content.PreviousUserPrincipal |
                Should -Be 'olduser@example.com'

            $content.NewUserPrincipal |
                Should -Be 'newuser@example.com'

            $content.VerificationStatus |
                Should -Be 'Verified'

            $content.SchemaVersion |
                Should -Be '1.0'
        }
    }

It 'creates the output directory when it does not exist' {
    InModuleScope PrimaryUserAudit `
        -Parameters @{
            RollbackRecord =
                $RollbackRecord
        } {

        $newOutputDirectory =
            Join-Path `
                $TestDrive `
                'NewRollbackDirectory'

        if (
            Test-Path `
                -LiteralPath $newOutputDirectory
        ) {
            Remove-Item `
                -LiteralPath $newOutputDirectory `
                -Recurse `
                -Force
        }

        Test-Path `
            -LiteralPath $newOutputDirectory |
            Should -BeFalse

        Export-PrimaryUserRollbackRecord `
            -Record $RollbackRecord `
            -OutputDirectory $newOutputDirectory |
            Out-Null

        Test-Path `
            -LiteralPath $newOutputDirectory `
            -PathType Container |
            Should -BeTrue
    }
}

    It 'supports multiple rollback records' {
        InModuleScope PrimaryUserAudit `
            -Parameters @{
                RollbackRecord =
                    $RollbackRecord

                TestOutputDirectory =
                    $TestOutputDirectory
            } {

            $secondRecord =
                $RollbackRecord.PSObject.Copy()

            $secondRecord.DeviceName =
                'PBI-TEST-002'

            $records =
                @(
                    $RollbackRecord
                    $secondRecord
                )

            $result =
                Export-PrimaryUserRollbackRecord `
                    -Record $records `
                    -OutputDirectory $TestOutputDirectory

            $content =
                Get-Content `
                    -LiteralPath $result.OutputPath `
                    -Raw |
                ConvertFrom-Json

            $result.RecordCount |
                Should -Be 2

            @($content).Count |
                Should -Be 2
        }
    }

    It 'supports an explicit output path' {
        InModuleScope PrimaryUserAudit `
            -Parameters @{
                RollbackRecord =
                    $RollbackRecord
            } {

            $explicitPath =
                Join-Path `
                    $TestDrive `
                    'Custom\rollback.json'

            $result =
                Export-PrimaryUserRollbackRecord `
                    -Record $RollbackRecord `
                    -OutputPath $explicitPath

            $result.OutputPath |
                Should -Be (
                    (Resolve-Path $explicitPath).Path
                )
        }
    }
}

AfterAll {
    Remove-Module `
        PrimaryUserAudit `
        -Force `
        -ErrorAction SilentlyContinue
}
