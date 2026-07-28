BeforeAll {
    $functionPath = Join-Path `
        $PSScriptRoot `
        '..\Private\Get-PrimaryUserRecommendation.ps1'

    . $functionPath
}

Describe 'Get-PrimaryUserRecommendation' {
    Context 'when a device has no sign-in evidence' {
        BeforeAll {
            $devices = @(
                [pscustomobject]@{
                    DeviceName             = 'TEST-PC-001'
                    EntraDeviceId        = 'device-001'
                    ManagedDeviceId      = 'managed-device-001'
                    CurrentUserPrincipal    = $null
                    CurrentUserDisplayName = $null
                    CurrentUserName        = $null
                    CurrentUserId          = $null
                    ComplianceState         = 'compliant'
                    Manufacturer            = 'Test Manufacturer'
                    Model                   = 'Test Model'
                    SerialNumber          = 'SERIAL001'
                    LastSyncDateTime       = Get-Date
                }
            )

            $result = @(
                Get-PrimaryUserRecommendation `
                    -Devices $devices `
                    -SignInEvidence @() `
                    -MinimumSignIns 5 `
                    -MinimumDominancePercent 70
            )
        }

        It 'returns one recommendation record' {
            $result.Count | Should -Be 1
        }

        It 'returns NoEvidence' {
            $result[0].RecommendedAction |
                Should -Be 'NoEvidence'
        }
    }

    Context 'when one user clearly dominates device usage' {
        BeforeAll {
            $devices = @(
                [pscustomobject]@{
                    DeviceName             = 'TEST-PC-002'
                    EntraDeviceId        = 'device-002'
                    ManagedDeviceId      = 'managed-device-002'
                    CurrentUserPrincipal    = $null
                    CurrentUserDisplayName = $null
                    CurrentUserName        = $null
                    CurrentUserId          = $null
                    ComplianceState         = 'compliant'
                    Manufacturer            = 'Test Manufacturer'
                    Model                   = 'Test Model'
                    SerialNumber          = 'SERIAL002'
                    LastSyncDateTime       = Get-Date
                }
            )

            $evidence = @(
                1..8 | ForEach-Object {
                    [pscustomobject]@{
                        UserPrincipalName = 'user1@contoso.com'
                        UserDisplayName   = 'user1'
                        UserId            = 'user1-id'
                        EntraDeviceId        = 'device-002'
                        ManagedDeviceId      = 'managed-device-002'
                        DeviceDisplayName  = 'TEST-PC-002'
                        CreatedDateTime    = (Get-Date).AddDays(-$_)
                        IsInteractive      = $true
                        Application        = 'Windows Sign In'
                    }
                }
            )

            $result = @(
                Get-PrimaryUserRecommendation `
                    -Devices $devices `
                    -SignInEvidence $evidence `
                    -MinimumSignIns 5 `
                    -MinimumDominancePercent 70
            )
        }

        It 'recommends the dominant user' {
            $result[0].RecommendedUserPrincipal |
                Should -Be 'user1@contoso.com'
        }

        It 'recommends assignment for an unassigned device' {
            $result[0].RecommendedAction |
                Should -Be 'Assign'
        }

        It 'calculates 100 percent dominance' {
            [math]::Round(
                [double]$result[0].DominancePercent,
                0
            ) | Should -Be 100
        }
    }

    Context 'when the current user is already correct' {
        BeforeAll {
            $devices = @(
                [pscustomobject]@{
                    DeviceName             = 'TEST-PC-003'
                    EntraDeviceId        = 'device-003'
                    ManagedDeviceId      = 'managed-device-003'
                    CurrentUserPrincipal    = 'user1@contoso.com'
                    CurrentUserDisplayName = 'user1'
                    CurrentUserName        = 'user1'
                    CurrentUserId          = 'user1-id'
                    ComplianceState         = 'compliant'
                    Manufacturer            = 'Test Manufacturer'
                    Model                   = 'Test Model'
                    SerialNumber          = 'SERIAL003'
                    LastSyncDateTime       = Get-Date
                }
            )

            $evidence = @(
                1..10 | ForEach-Object {
                    [pscustomobject]@{
                        UserPrincipalName = 'user1@contoso.com'
                        UserDisplayName   = 'user1'
                        UserId            = 'user1-id'
                        EntraDeviceId        = 'device-003'
                        ManagedDeviceId      = 'managed-device-003'
                        DeviceDisplayName  = 'TEST-PC-003'
                        CreatedDateTime    = (Get-Date).AddHours(-$_)
                        IsInteractive      = $true
                        Application        = 'Windows Sign In'
                    }
                }
            )

            $result = @(
                Get-PrimaryUserRecommendation `
                    -Devices $devices `
                    -SignInEvidence $evidence `
                    -MinimumSignIns 5 `
                    -MinimumDominancePercent 70
            )
        }

        It 'recommends no change' {
            $result[0].RecommendedAction |
                Should -Be 'NoChange'
        }
    }

    Context 'when another user clearly dominates usage' {
        BeforeAll {
            $devices = @(
                [pscustomobject]@{
                    DeviceName             = 'TEST-PC-004'
                    EntraDeviceId        = 'device-004'
                    ManagedDeviceId      = 'managed-device-004'
                    CurrentUserPrincipal    = 'olduser@contoso.com'
                    CurrentUserDisplayName = 'olduser'
                    CurrentUserName        = 'olduser'
                    CurrentUserId          = 'olduser-id'
                    ComplianceState         = 'compliant'
                    Manufacturer            = 'Test Manufacturer'
                    Model                   = 'Test Model'
                    SerialNumber          = 'SERIAL004'
                    LastSyncDateTime       = Get-Date
                }
            )

            $evidence = @(
                1..8 | ForEach-Object {
                    [pscustomobject]@{
                        UserPrincipalName = 'newuser@contoso.com'
                        UserDisplayName   = 'newuser'
                        UserId            = 'newuser-id'
                        EntraDeviceId        = 'device-004'
                        ManagedDeviceId      = 'managed-device-004'
                        DeviceDisplayName  = 'TEST-PC-004'
                        CreatedDateTime    = (Get-Date).AddHours(-$_)
                        IsInteractive      = $true
                        Application        = 'Windows Sign In'
                    }
                }

                1..2 | ForEach-Object {
                    [pscustomobject]@{
                        UserPrincipalName = 'olduser@contoso.com'
                        UserDisplayName   = 'olduser'
                        UserId            = 'olduser-id'
                        EntraDeviceId        = 'device-004'
                        ManagedDeviceId      = 'managed-device-004'
                        DeviceDisplayName  = 'TEST-PC-004'
                        CreatedDateTime    = (Get-Date).AddDays(-$_)
                        IsInteractive      = $true
                        Application        = 'Windows Sign In'
                    }
                }
            )

            $result = @(
                Get-PrimaryUserRecommendation `
                    -Devices $devices `
                    -SignInEvidence $evidence `
                    -MinimumSignIns 5 `
                    -MinimumDominancePercent 70
            )
        }

        It 'recommends changing the current user' {
            $result[0].RecommendedAction |
                Should -Be 'Change'
        }

        It 'recommends the leading user' {
            $result[0].RecommendedUserPrincipal |
                Should -Be 'newuser@contoso.com'
        }

        It 'calculates 80 percent dominance' {
            [math]::Round(
                [double]$result[0].DominancePercent,
                0
            ) | Should -Be 80
        }
    }

    Context 'when usage is too evenly divided' {
        BeforeAll {
            $devices = @(
                [pscustomobject]@{
                    DeviceName             = 'TEST-PC-005'
                    EntraDeviceId        = 'device-005'
                    ManagedDeviceId      = 'managed-device-005'
                    CurrentUserPrincipal    = 'user1@contoso.com'
                    CurrentUserDisplayName = 'user1'
                    CurrentUserName        = 'user1'
                    CurrentUserId          = 'user1-id'
                    ComplianceState         = 'compliant'
                    Manufacturer            = 'Test Manufacturer'
                    Model                   = 'Test Model'
                    SerialNumber          = 'SERIAL005'
                    LastSyncDateTime       = Get-Date
                }
            )

            $evidence = @(
                1..6 | ForEach-Object {
                    [pscustomobject]@{
                        UserPrincipalName = 'user1@contoso.com'
                        UserDisplayName   = 'user1'
                        UserId            = 'user1-id'
                        EntraDeviceId        = 'device-005'
                        ManagedDeviceId      = 'managed-device-005'
                        DeviceDisplayName  = 'TEST-PC-005'
                        CreatedDateTime    = (Get-Date).AddHours(-$_)
                        IsInteractive      = $true
                        Application        = 'Windows Sign In'
                    }
                }

                1..4 | ForEach-Object {
                    [pscustomobject]@{
                        UserPrincipalName = 'user2@contoso.com'
                        UserDisplayName   = 'user2'
                        UserId            = 'user2-id'
                        EntraDeviceId        = 'device-005'
                        ManagedDeviceId      = 'managed-device-005'
                        DeviceDisplayName  = 'TEST-PC-005'
                        CreatedDateTime    = (Get-Date).AddDays(-$_)
                        IsInteractive      = $true
                        Application        = 'Windows Sign In'
                    }
                }
            )

            $result = @(
                Get-PrimaryUserRecommendation `
                    -Devices $devices `
                    -SignInEvidence $evidence `
                    -MinimumSignIns 5 `
                    -MinimumDominancePercent 70
            )
        }

        It 'requires manual review' {
            $result[0].RecommendedAction |
                Should -Be 'Review'
        }
    }
}







