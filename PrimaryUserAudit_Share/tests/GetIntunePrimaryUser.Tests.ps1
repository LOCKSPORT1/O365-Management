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

    $AssignedUserId =
        '22222222-2222-2222-2222-222222222222'
}

Describe 'Get-IntunePrimaryUser' {
    Context 'Input validation' {
        It 'throws when ManagedDeviceId is invalid' {
            InModuleScope PrimaryUserAudit {
                {
                    Get-IntunePrimaryUser `
                        -ManagedDeviceId 'not-a-guid'
                } |
                    Should -Throw '*ManagedDeviceId*valid GUID*'
            }
        }

        It 'marks ManagedDeviceId as mandatory' {
            InModuleScope PrimaryUserAudit {
                $command =
                    Get-Command Get-IntunePrimaryUser

                $mandatory = @(
                    $command.Parameters[
                        'ManagedDeviceId'
                    ].Attributes |
                    Where-Object {
                        $_.PSObject.Properties.Name -contains
                        'Mandatory'
                    } |
                    Select-Object `
                        -ExpandProperty Mandatory
                )

                $mandatory |
                    Should -Contain $true
            }
        }
    }

    Context 'Graph request construction' {
        It 'queries the managed-device users relationship' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId =
                        $ManagedDeviceId

                    AssignedUserId =
                        $AssignedUserId
                } {

                Mock Invoke-GraphRequestWithRetry {
                    [pscustomobject]@{
                        value = @(
                            [pscustomobject]@{
                                id =
                                    $AssignedUserId

                                userPrincipalName =
                                    'assigneduser@example.com'

                                displayName =
                                    'Assigned User'
                            }
                        )
                    }
                }

                $result =
                    Get-IntunePrimaryUser `
                        -ManagedDeviceId $ManagedDeviceId

                $result.AssignedUserId |
                    Should -Be $AssignedUserId

                $result.AssignedUserPrincipal |
                    Should -Be 'assigneduser@example.com'

                $result.AssignedUserName |
                    Should -Be 'Assigned User'

                $result.AssignedUserCount |
                    Should -Be 1

                $result.QueryStatus |
                    Should -Be 'Retrieved'

                Should `
                    -Invoke Invoke-GraphRequestWithRetry `
                    -Times 1 `
                    -ParameterFilter {
                        $Method -eq 'GET' -and

                        $Uri -eq (
                            "https://graph.microsoft.com/v1.0/" +
                            "deviceManagement/managedDevices(" +
                            "'$ManagedDeviceId')/users"
                        )
                    }
            }
        }
    }

    Context 'No assigned user' {
        It 'returns NoUserAssigned for an empty Graph result' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId =
                        $ManagedDeviceId
                } {

                Mock Invoke-GraphRequestWithRetry {
                    [pscustomobject]@{
                        value = @()
                    }
                }

                $result =
                    Get-IntunePrimaryUser `
                        -ManagedDeviceId $ManagedDeviceId

                $result.AssignedUserId |
                    Should -BeNullOrEmpty

                $result.AssignedUserPrincipal |
                    Should -BeNullOrEmpty

                $result.AssignedUserCount |
                    Should -Be 0

                $result.QueryStatus |
                    Should -Be 'NoUserAssigned'
            }
        }
    }

    Context 'Multiple returned users' {
        It 'returns the first assigned user and reports the count' {
            InModuleScope PrimaryUserAudit `
                -Parameters @{
                    ManagedDeviceId =
                        $ManagedDeviceId

                    AssignedUserId =
                        $AssignedUserId
                } {

                Mock Invoke-GraphRequestWithRetry {
                    [pscustomobject]@{
                        value = @(
                            [pscustomobject]@{
                                id =
                                    $AssignedUserId

                                userPrincipalName =
                                    'firstuser@example.com'

                                displayName =
                                    'First User'
                            }

                            [pscustomobject]@{
                                id =
                                    '33333333-3333-3333-3333-333333333333'

                                userPrincipalName =
                                    'seconduser@example.com'

                                displayName =
                                    'Second User'
                            }
                        )
                    }
                }

                $result =
                    Get-IntunePrimaryUser `
                        -ManagedDeviceId $ManagedDeviceId

                $result.AssignedUserId |
                    Should -Be $AssignedUserId

                $result.AssignedUserCount |
                    Should -Be 2
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
