$modulePath = Join-Path `
    $PSScriptRoot `
    '..\O365Toolkit.Entra.psd1'

Import-Module `
    $modulePath `
    -Force `
    -ErrorAction Stop

Describe 'O365Toolkit.Entra module' {
    It 'has a valid module manifest' {
        $manifestPath = Join-Path `
            $PSScriptRoot `
            '..\O365Toolkit.Entra.psd1'

        Test-ModuleManifest `
            -Path $manifestPath `
            -ErrorAction Stop |
            Should -Not -BeNullOrEmpty
    }

    It 'exports Get-ToolkitUser' {
        Get-Command `
            Get-ToolkitUser `
            -Module O365Toolkit.Entra `
            -ErrorAction Stop |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-ToolkitUser' {
    InModuleScope O365Toolkit.Entra {
        BeforeEach {
            $script:config = [pscustomobject]@{
                Logging = [pscustomobject]@{
                    Enabled = $false
                }
            }
        }

        It 'retrieves one user by UPN' {
            Mock Invoke-ToolkitGraphRequest {
                [pscustomobject]@{
                    Success    = $true
                    DurationMs = 25
                    Data       = [pscustomobject]@{
                        id                = 'user-1'
                        displayName       = 'Joshua Christy'
                        userPrincipalName = 'JChristy@panelbuilt.com'
                    }
                }
            }

            $result = Get-ToolkitUser `
                -UserPrincipalName 'jchristy@panelbuilt.com' `
                -Config $script:config

            $result.userPrincipalName |
                Should -Be 'JChristy@panelbuilt.com'

            Should -Invoke `
                Invoke-ToolkitGraphRequest `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Method -eq 'GET' -and
                    $Uri -match 'jchristy%40panelbuilt\.com'
                }
        }

        It 'retrieves all users using paging' {
            Mock Invoke-ToolkitGraphRequest {
                [pscustomobject]@{
                    Success     = $true
                    DurationMs  = 100
                    PageCount   = 2
                    RecordCount = 2
                    Data        = @(
                        [pscustomobject]@{
                            displayName = 'User One'
                        }
                        [pscustomobject]@{
                            displayName = 'User Two'
                        }
                    )
                }
            }

            $result = Get-ToolkitUser `
                -Config $script:config `
                -PassThru

            $result.Success |
                Should -BeTrue

            $result.QueryType |
                Should -Be 'All'

            $result.RecordCount |
                Should -Be 2

            Should -Invoke `
                Invoke-ToolkitGraphRequest `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Method -eq 'GET' -and
                    $AllPages
                }
        }

        It 'filters users by department' {
            Mock Invoke-ToolkitGraphRequest {
                [pscustomobject]@{
                    Success    = $true
                    DurationMs = 100
                    PageCount  = 1
                    Data       = @(
                        [pscustomobject]@{
                            displayName = 'Engineer One'
                            department  = 'Engineering'
                        }
                        [pscustomobject]@{
                            displayName = 'IT User'
                            department  = 'Information Technology'
                        }
                    )
                }
            }

            $result = Get-ToolkitUser `
                -Department 'Engineering' `
                -Config $script:config `
                -PassThru

            $result.RecordCount |
                Should -Be 1

            $result.Data[0].displayName |
                Should -Be 'Engineer One'
        }

        It 'filters licensed users' {
            Mock Invoke-ToolkitGraphRequest {
                [pscustomobject]@{
                    Success    = $true
                    DurationMs = 100
                    PageCount  = 1
                    Data       = @(
                        [pscustomobject]@{
                            displayName     = 'Licensed User'
                            assignedLicenses = @(
                                [pscustomobject]@{
                                    skuId = 'sku-1'
                                }
                            )
                        }
                        [pscustomobject]@{
                            displayName     = 'Unlicensed User'
                            assignedLicenses = @()
                        }
                    )
                }
            }

            $result = Get-ToolkitUser `
                -LicensedOnly `
                -Config $script:config `
                -PassThru

            $result.RecordCount |
                Should -Be 1

            $result.Data[0].displayName |
                Should -Be 'Licensed User'
        }

        It 'returns metadata for a UPN lookup with PassThru' {
            Mock Invoke-ToolkitGraphRequest {
                [pscustomobject]@{
                    Success    = $true
                    DurationMs = 42
                    Data       = [pscustomobject]@{
                        displayName       = 'Joshua Christy'
                        userPrincipalName = 'JChristy@panelbuilt.com'
                    }
                }
            }

            $result = Get-ToolkitUser `
                -UserPrincipalName 'jchristy@panelbuilt.com' `
                -Config $script:config `
                -PassThru

            $result.Success |
                Should -BeTrue

            $result.QueryType |
                Should -Be 'UserPrincipalName'

            $result.RecordCount |
                Should -Be 1

            $result.DurationMs |
                Should -Be 42
        }
    }
}