BeforeAll {
    $modulePath = Join-Path `
        $PSScriptRoot `
        '..\PrimaryUserAudit.psd1'

    Import-Module `
        $modulePath `
        -Force

    $ManagedDeviceId =
        '11111111-1111-1111-1111-111111111111'

    $UserId =
        '22222222-2222-2222-2222-222222222222'
}

Describe 'Set-IntunePrimaryUser' {
    Context 'Request construction' {
        It 'builds the expected Microsoft Graph request' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId = $ManagedDeviceId
                    UserId          = $UserId
                } {

                $result = Set-IntunePrimaryUser `
                    -ManagedDeviceId $ManagedDeviceId `
                    -UserId $UserId

                $result.Method |
                    Should -Be 'POST'

                $result.Uri |
                    Should -Be (
                        "https://graph.microsoft.com/v1.0/" +
                        "deviceManagement/managedDevices(" +
                        "'$ManagedDeviceId')/users/`$ref"
                    )

                $result.Body.'@odata.id' |
                    Should -Be (
                        "https://graph.microsoft.com/v1.0/" +
                        "users/$UserId"
                    )

                $result.ExecutionStatus |
                    Should -Be 'Planned'
            }
        }

        It 'does not call Graph without Execute' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId = $ManagedDeviceId
                    UserId          = $UserId
                } {

                Mock Invoke-GraphRequestWithRetry {
                    throw 'Graph should not be called.'
                }

                Set-IntunePrimaryUser `
                    -ManagedDeviceId $ManagedDeviceId `
                    -UserId $UserId |
                    Out-Null

                Should `
                    -Invoke Invoke-GraphRequestWithRetry `
                    -Times 0
            }
        }
    }

    Context 'Input validation' {
        It 'throws for an invalid managed-device ID' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    UserId = $UserId
                } {

                {
                    Set-IntunePrimaryUser `
                        -ManagedDeviceId 'not-a-guid' `
                        -UserId $UserId
                } |
                    Should -Throw '*ManagedDeviceId*valid GUID*'
            }
        }

        It 'throws for an invalid user ID' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId = $ManagedDeviceId
                } {

                {
                    Set-IntunePrimaryUser `
                        -ManagedDeviceId $ManagedDeviceId `
                        -UserId 'not-a-guid'
                } |
                    Should -Throw '*UserId*valid GUID*'
            }
        }

        It 'marks ManagedDeviceId as mandatory' {
            InModuleScope PrimaryUserAudit {
                $command = Get-Command Set-IntunePrimaryUser

                $mandatory = @(
                    $command.Parameters['ManagedDeviceId'].Attributes |
                    Where-Object {
                        $_.PSObject.Properties.Name -contains 'Mandatory'
                    } |
                    Select-Object -ExpandProperty Mandatory
                )

                $mandatory |
                    Should -Contain $true
            }
        }

        It 'marks UserId as mandatory' {
            InModuleScope PrimaryUserAudit {
                $command = Get-Command Set-IntunePrimaryUser

                $mandatory = @(
                    $command.Parameters['UserId'].Attributes |
                    Where-Object {
                        $_.PSObject.Properties.Name -contains 'Mandatory'
                    } |
                    Select-Object -ExpandProperty Mandatory
                )

                $mandatory |
                    Should -Contain $true
            }
        }
    }

    Context 'Graph execution' {
        It 'calls the Graph wrapper when Execute is supplied' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId = $ManagedDeviceId
                    UserId          = $UserId
                } {

                Mock Invoke-GraphRequestWithRetry {
                    [pscustomobject]@{
                        Status = 'MockSuccess'
                    }
                }

                $result = Set-IntunePrimaryUser `
                    -ManagedDeviceId $ManagedDeviceId `
                    -UserId $UserId `
                    -Execute

                $result.ExecutionStatus |
                    Should -Be 'Completed'

                $result.GraphResponse.Status |
                    Should -Be 'MockSuccess'

                Should `
                    -Invoke Invoke-GraphRequestWithRetry `
                    -Times 1 `
                    -ParameterFilter {
                        $Method -eq 'POST' -and
                        $Uri -eq (
                            "https://graph.microsoft.com/v1.0/" +
                            "deviceManagement/managedDevices(" +
                            "'$ManagedDeviceId')/users/`$ref"
                        ) -and
                        $Body.'@odata.id' -eq (
                            "https://graph.microsoft.com/v1.0/" +
                            "users/$UserId"
                        ) -and
                        $DisablePagination
                    }
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
