$manifestPath = Join-Path `
    $PSScriptRoot `
    '..\O365Toolkit.Core.psd1'

Get-Module O365Toolkit.Core -All |
    Remove-Module `
        -Force `
        -ErrorAction SilentlyContinue

Import-Module `
    -Name $manifestPath `
    -Force `
    -ErrorAction Stop

Describe 'Graph request module exports' {
    It 'exports Invoke-ToolkitGraphRequest' {
        Get-Command `
            Invoke-ToolkitGraphRequest `
            -Module O365Toolkit.Core `
            -ErrorAction Stop |
            Should -Not -BeNullOrEmpty
    }

    It 'does not export Invoke-ToolkitGraphRequestPipeline' {
        Get-Command `
            Invoke-ToolkitGraphRequestPipeline `
            -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'does not export Invoke-GraphRequestWithRetry' {
        Get-Command `
            Invoke-GraphRequestWithRetry `
            -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
}

Describe 'Invoke-ToolkitGraphRequest' {
    InModuleScope O365Toolkit.Core {
        BeforeEach {
            $script:testConfig = [pscustomobject]@{
                Tenant = [pscustomobject]@{
                    TenantId    = '11111111-1111-1111-1111-111111111111'
                    Environment = 'Global'
                }

                Graph = [pscustomobject]@{
                    RequiredScopes = @('User.Read.All')
                }

                Logging = [pscustomobject]@{
                    Enabled          = $false
                    MinimumLevel     = 'Information'
                    UseDailyLogFiles = $false
                    Directory        = $TestDrive
                    FileName         = 'test.log'
                }
            }

            Mock Write-ToolkitLog
            Mock Invoke-ToolkitGraphRequestPipeline
        }

        It 'throws when no valid Graph connection exists' {
            Mock Test-ToolkitGraphConnection {
                [pscustomobject]@{
                    IsValid = $false
                }
            }

            {
                Invoke-ToolkitGraphRequest `
                    -Method GET `
                    -Uri 'https://graph.microsoft.com/v1.0/organization' `
                    -Config $script:testConfig `
                    -ErrorAction Stop
            } | Should -Throw '*No valid Microsoft Graph connection exists*'

            Should -Invoke `
                Invoke-ToolkitGraphRequestPipeline `
                -Times 0 `
                -Exactly
        }

        It 'returns the Graph response without PassThru' {
            Mock Test-ToolkitGraphConnection {
                [pscustomobject]@{
                    IsValid = $true
                }
            }

            Mock Invoke-ToolkitGraphRequestPipeline {
                [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            id          = 'tenant-id'
                            displayName = 'Panel Built'
                        }
                    )
                }
            }

            $result = Invoke-ToolkitGraphRequest `
                -Method GET `
                -Uri 'https://graph.microsoft.com/v1.0/organization' `
                -Config $script:testConfig

            $result.value[0].displayName |
                Should -Be 'Panel Built'

            Should -Invoke `
                Invoke-ToolkitGraphRequestPipeline `
                -Times 1 `
                -Exactly
        }

        It 'returns metadata when PassThru is specified' {
            Mock Test-ToolkitGraphConnection {
                [pscustomobject]@{
                    IsValid = $true
                }
            }

            Mock Invoke-ToolkitGraphRequestPipeline {
                [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            displayName = 'Panel Built'
                        }
                    )
                }
            }

            $result = Invoke-ToolkitGraphRequest `
                -Method GET `
                -Uri 'https://graph.microsoft.com/v1.0/organization' `
                -Config $script:testConfig `
                -MaxAttempts 6 `
                -MaximumRetryDelaySeconds 20 `
                -PassThru

            $result.Success |
                Should -BeTrue

            $result.Method |
                Should -Be 'GET'

            $result.MaxAttempts |
                Should -Be 6

            $result.DurationMs |
                Should -BeGreaterOrEqual 0

            $result.StartedAt |
                Should -BeOfType ([datetime])

            $result.CompletedAt |
                Should -BeOfType ([datetime])

            $result.Data.value[0].displayName |
                Should -Be 'Panel Built'
        }

        It 'passes Body and Headers to the pipeline' {
            Mock Test-ToolkitGraphConnection {
                [pscustomobject]@{
                    IsValid = $true
                }
            }

            Mock Invoke-ToolkitGraphRequestPipeline {
                [pscustomobject]@{
                    id = 'created-object'
                }
            }

            $body = @{
                displayName = 'Test User'
            }

            $headers = @{
                ConsistencyLevel = 'eventual'
            }

            Invoke-ToolkitGraphRequest `
                -Method POST `
                -Uri 'https://graph.microsoft.com/v1.0/users' `
                -Body $body `
                -Headers $headers `
                -Config $script:testConfig

            Should -Invoke `
                Invoke-ToolkitGraphRequestPipeline `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Method -eq 'POST' -and
                    $Body.displayName -eq 'Test User' -and
                    $Headers.ConsistencyLevel -eq 'eventual'
                }
        }
    }
}

Describe 'Invoke-GraphRequestWithRetry' {
    InModuleScope O365Toolkit.Core {
        BeforeEach {
            Mock Start-Sleep

            Mock Get-ToolkitGraphRetryDelay {
                1
            }
        }

        It 'returns immediately after a successful request' {
            Mock Invoke-MgGraphRequest {
                [pscustomobject]@{
                    value = 'success'
                }
            }

            $result = Invoke-GraphRequestWithRetry `
                -Method GET `
                -Uri 'https://graph.microsoft.com/v1.0/organization'

            $result.value |
                Should -Be 'success'

            Should -Invoke `
                Invoke-MgGraphRequest `
                -Times 1 `
                -Exactly

            Should -Invoke `
                Start-Sleep `
                -Times 0 `
                -Exactly
        }

        It 'does not retry a non-retryable 400 response' {
            Mock Invoke-MgGraphRequest {
                throw [System.Exception]::new('Bad request')
            }

            Mock Resolve-ToolkitGraphError {
                [pscustomobject]@{
                    StatusCode  = 400
                    IsRetryable = $false
                }
            }

            {
                Invoke-GraphRequestWithRetry `
                    -Method GET `
                    -Uri 'https://graph.microsoft.com/v1.0/bad' `
                    -MaxAttempts 4
            } | Should -Throw '*Bad request*'

            Should -Invoke `
                Invoke-MgGraphRequest `
                -Times 1 `
                -Exactly

            Should -Invoke `
                Start-Sleep `
                -Times 0 `
                -Exactly
        }

        It 'retries a 429 response and then succeeds' {
            $script:requestAttempt = 0

            Mock Invoke-MgGraphRequest {
                $script:requestAttempt++

                if ($script:requestAttempt -eq 1) {
                    throw [System.Exception]::new('Throttled')
                }

                [pscustomobject]@{
                    value = 'success'
                }
            }

            Mock Resolve-ToolkitGraphError {
                [pscustomobject]@{
                    StatusCode  = 429
                    IsRetryable = $true
                }
            }

            $result = Invoke-GraphRequestWithRetry `
                -Method GET `
                -Uri 'https://graph.microsoft.com/v1.0/users' `
                -MaxAttempts 4

            $result.value |
                Should -Be 'success'

            Should -Invoke `
                Invoke-MgGraphRequest `
                -Times 2 `
                -Exactly

            Should -Invoke `
                Get-ToolkitGraphRetryDelay `
                -Times 1 `
                -Exactly

            Should -Invoke `
                Start-Sleep `
                -Times 1 `
                -Exactly
        }

        It 'throws after reaching the maximum attempts' {
            Mock Invoke-MgGraphRequest {
                throw [System.Exception]::new(
                    'Service unavailable'
                )
            }

            Mock Resolve-ToolkitGraphError {
                [pscustomobject]@{
                    StatusCode  = 503
                    IsRetryable = $true
                }
            }

            {
                Invoke-GraphRequestWithRetry `
                    -Method GET `
                    -Uri 'https://graph.microsoft.com/v1.0/users' `
                    -MaxAttempts 3
            } | Should -Throw '*Service unavailable*'

            Should -Invoke `
                Invoke-MgGraphRequest `
                -Times 3 `
                -Exactly

            Should -Invoke `
                Start-Sleep `
                -Times 2 `
                -Exactly
        }
    }
}

Describe 'Get-ToolkitGraphRetryDelay' {
    InModuleScope O365Toolkit.Core {
        It 'does not exceed the configured maximum delay' {
            $delay = Get-ToolkitGraphRetryDelay `
                -RetryAttempt 6 `
                -MaximumDelaySeconds 5

            $delay |
                Should -BeGreaterOrEqual 1

            $delay |
                Should -BeLessOrEqual 5
        }

        It 'uses exponential backoff when Retry-After is unavailable' {
            Mock Get-Random {
                100
            }

            $delay = Get-ToolkitGraphRetryDelay `
                -RetryAttempt 2 `
                -MaximumDelaySeconds 60

            $delay |
                Should -Be 5
        }
    }
}
