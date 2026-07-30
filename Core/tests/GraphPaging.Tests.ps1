$modulePath = Join-Path `
    $PSScriptRoot `
    '..\O365Toolkit.Core.psd1'

Import-Module `
    $modulePath `
    -Force

Describe 'Microsoft Graph paging' {
    InModuleScope O365Toolkit.Core {
        BeforeEach {
            $script:config = [pscustomobject]@{
                Logging = [pscustomobject]@{
                    Enabled = $false
                }
            }

            Mock Test-ToolkitGraphConnection {
                [pscustomobject]@{
                    IsValid = $true
                }
            }

            Mock Write-ToolkitLog {}

            Mock Resolve-ToolkitGraphError {
                [pscustomobject]@{
                    StatusCode = $null
                    RequestId  = $null
                    Message    = 'Test failure'
                }
            }
        }

        It 'retrieves records from two pages' {
            $script:requestNumber = 0

            Mock Invoke-ToolkitGraphRequestPipeline {
                $script:requestNumber++

                if ($script:requestNumber -eq 1) {
                    return @{
                        value = @(
                            [pscustomobject]@{ id = '1' }
                            [pscustomobject]@{ id = '2' }
                        )
                        '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?page=2'
                    }
                }

                return @{
                    value = @(
                        [pscustomobject]@{ id = '3' }
                    )
                }
            }

            $result = Invoke-ToolkitGraphRequest `
                -Method GET `
                -Uri 'https://graph.microsoft.com/v1.0/users' `
                -Config $script:config `
                -AllPages

            @($result).Count | Should -Be 3
            @($result).id | Should -Be @(
                '1'
                '2'
                '3'
            )

            Should -Invoke `
                Invoke-ToolkitGraphRequestPipeline `
                -Times 2 `
                -Exactly
        }

        It 'retrieves records from three pages' {
            $script:requestNumber = 0

            Mock Invoke-ToolkitGraphRequestPipeline {
                $script:requestNumber++

                switch ($script:requestNumber) {
                    1 {
                        return @{
                            value = @(
                                [pscustomobject]@{ id = '1' }
                            )
                            '@odata.nextLink' = 'page-2'
                        }
                    }

                    2 {
                        return @{
                            value = @(
                                [pscustomobject]@{ id = '2' }
                            )
                            '@odata.nextLink' = 'page-3'
                        }
                    }

                    default {
                        return @{
                            value = @(
                                [pscustomobject]@{ id = '3' }
                            )
                        }
                    }
                }
            }

            $result = Invoke-ToolkitGraphRequest `
                -Method GET `
                -Uri 'page-1' `
                -Config $script:config `
                -AllPages

            @($result).Count | Should -Be 3

            Should -Invoke `
                Invoke-ToolkitGraphRequestPipeline `
                -Times 3 `
                -Exactly
        }

        It 'stops at the configured page limit' {
            $script:requestNumber = 0

            Mock Invoke-ToolkitGraphRequestPipeline {
                $script:requestNumber++

                return @{
                    value = @(
                        [pscustomobject]@{
                            id = [string]$script:requestNumber
                        }
                    )
                    '@odata.nextLink' = "page-$($script:requestNumber + 1)"
                }
            }

            $result = Invoke-ToolkitGraphRequest `
                -Method GET `
                -Uri 'page-1' `
                -Config $script:config `
                -AllPages `
                -PageLimit 2 `
                -PassThru

            $result.PageCount | Should -Be 2
            $result.RecordCount | Should -Be 2
            $result.IsTruncated | Should -BeTrue
            $result.PageLimit | Should -Be 2
            @($result.Data).Count | Should -Be 2

            Should -Invoke `
                Invoke-ToolkitGraphRequestPipeline `
                -Times 2 `
                -Exactly
        }

        It 'returns paging telemetry with PassThru' {
            $script:requestNumber = 0

            Mock Invoke-ToolkitGraphRequestPipeline {
                $script:requestNumber++

                if ($script:requestNumber -eq 1) {
                    return @{
                        value = @(
                            [pscustomobject]@{ id = '1' }
                            [pscustomobject]@{ id = '2' }
                        )
                        '@odata.nextLink' = 'page-2'
                    }
                }

                return @{
                    value = @(
                        [pscustomobject]@{ id = '3' }
                    )
                }
            }

            $result = Invoke-ToolkitGraphRequest `
                -Method GET `
                -Uri 'page-1' `
                -Config $script:config `
                -AllPages `
                -PassThru

            $result.Success | Should -BeTrue
            $result.AllPages | Should -BeTrue
            $result.PageCount | Should -Be 2
            $result.RecordCount | Should -Be 3
            $result.IsTruncated | Should -BeFalse
            $result.PageLimit | Should -Be 0
            @($result.Data).Count | Should -Be 3
            $result.DurationMs | Should -BeGreaterOrEqual 0
        }

        It 'rejects AllPages for non-GET requests' {
            {
                Invoke-ToolkitGraphRequest `
                    -Method POST `
                    -Uri 'https://graph.microsoft.com/v1.0/users' `
                    -Body @{ displayName = 'Test' } `
                    -Config $script:config `
                    -AllPages
            } | Should -Throw `
                '*AllPages parameter can only be used with GET requests*'

            Should -Invoke `
                Test-ToolkitGraphConnection `
                -Times 0 `
                -Exactly
        }

        It 'rejects PageLimit without AllPages' {
            {
                Invoke-ToolkitGraphRequest `
                    -Method GET `
                    -Uri 'https://graph.microsoft.com/v1.0/users' `
                    -Config $script:config `
                    -PageLimit 2
            } | Should -Throw `
                '*PageLimit can only be used when AllPages is specified*'

            Should -Invoke `
                Test-ToolkitGraphConnection `
                -Times 0 `
                -Exactly
        }

                It 'throws when a paged response has no value collection' {
            Mock Invoke-ToolkitGraphRequestPipeline {
                @{
                    '@odata.context' = 'test'
                }
            }

            {
                Invoke-ToolkitGraphRequest `
                    -Method GET `
                    -Uri 'https://graph.microsoft.com/v1.0/users' `
                    -Config $script:config `
                    -AllPages
            } | Should -Throw `
                '*did not contain a value collection*'
        }
    }

    It 'keeps paging helpers private' {
        Get-Command `
            Get-ToolkitGraphNextLink `
            -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty

        Get-Command `
            Invoke-ToolkitGraphPagedRequest `
            -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
}