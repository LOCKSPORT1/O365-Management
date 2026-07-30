BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\O365Toolkit.Core.psd1'

    Remove-Module O365Toolkit.Core -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    $script:testConfig = [pscustomobject]@{
        Tenant = [pscustomobject]@{
            TenantId = ''
        }
        Graph = [pscustomobject]@{
            CloudEnvironment = 'Global'
            Scopes = @(
                'User.Read.All'
                'Directory.Read.All'
            )
        }
        Logging = [pscustomobject]@{
            Enabled = $false
        }
    }

    $script:validContext = [pscustomobject]@{
        Account      = 'admin@contoso.com'
        TenantId     = '11111111-1111-1111-1111-111111111111'
        Environment  = 'Global'
        AuthType     = 'Delegated'
        ContextScope = 'Process'
        Scopes       = @(
            'User.Read.All'
            'Directory.Read.All'
        )
    }
}

Describe 'Graph authentication module exports' {
    It 'exports Connect-ToolkitGraph' {
        Get-Command Connect-ToolkitGraph -Module O365Toolkit.Core |
            Should -Not -BeNullOrEmpty
    }

    It 'exports Test-ToolkitGraphConnection' {
        Get-Command Test-ToolkitGraphConnection -Module O365Toolkit.Core |
            Should -Not -BeNullOrEmpty
    }

    It 'exports Disconnect-ToolkitGraph' {
        Get-Command Disconnect-ToolkitGraph -Module O365Toolkit.Core |
            Should -Not -BeNullOrEmpty
    }

    It 'does not export Resolve-ToolkitGraphEnvironment' {
        Get-Command Resolve-ToolkitGraphEnvironment -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
}

Describe 'Resolve-ToolkitGraphEnvironment' {
    It 'maps <Cloud> to <Expected>' -ForEach @(
        @{ Cloud = 'Global';  Expected = 'Global' }
        @{ Cloud = 'GCC';     Expected = 'Global' }
        @{ Cloud = 'GCCHigh'; Expected = 'USGov' }
        @{ Cloud = 'DoD';     Expected = 'USGovDoD' }
        @{ Cloud = 'China';   Expected = 'China' }
    ) {
        InModuleScope O365Toolkit.Core {
            Resolve-ToolkitGraphEnvironment -CloudEnvironment $Cloud |
                Should -Be $Expected
        } -Parameters @{
            Cloud    = $Cloud
            Expected = $Expected
        }
    }

    It 'throws for an unsupported environment' {
        InModuleScope O365Toolkit.Core {
            {
                Resolve-ToolkitGraphEnvironment `
                    -CloudEnvironment 'UnsupportedCloud'
            } | Should -Throw
        }
    }
}

Describe 'Test-ToolkitGraphConnection' {
    It 'returns an invalid result when no Graph session exists' {
        InModuleScope O365Toolkit.Core {
            Mock Get-MgContext {
                throw 'SessionNotInitialized'
            }

            $result =
                Test-ToolkitGraphConnection `
                    -Config $testConfig `
                    -PassThru

            $result.IsValid | Should -BeFalse
            $result.Connected | Should -BeFalse
            $result.MissingScopes.Count | Should -Be 2
        } -Parameters @{
            testConfig = $script:testConfig
        }
    }

    It 'returns a valid result for a matching context' {
        InModuleScope O365Toolkit.Core {
            Mock Get-MgContext {
                $validContext
            }

            $result =
                Test-ToolkitGraphConnection `
                    -Config $testConfig `
                    -PassThru

            $result.IsValid | Should -BeTrue
            $result.Connected | Should -BeTrue
            $result.ScopesMatch | Should -BeTrue
            $result.EnvironmentMatches | Should -BeTrue
        } -Parameters @{
            testConfig   = $script:testConfig
            validContext = $script:validContext
        }
    }

    It 'identifies missing scopes' {
        InModuleScope O365Toolkit.Core {
            Mock Get-MgContext {
                [pscustomobject]@{
                    Account     = 'admin@contoso.com'
                    TenantId    = '11111111-1111-1111-1111-111111111111'
                    Environment = 'Global'
                    AuthType    = 'Delegated'
                    Scopes      = @('User.Read.All')
                }
            }

            $result =
                Test-ToolkitGraphConnection `
                    -Config $testConfig `
                    -PassThru

            $result.IsValid | Should -BeFalse
            $result.ScopesMatch | Should -BeFalse
            $result.MissingScopes |
                Should -Contain 'Directory.Read.All'
        } -Parameters @{
            testConfig = $script:testConfig
        }
    }
}

Describe 'Disconnect-ToolkitGraph' {
    It 'returns WasConnected false when no session exists' {
        InModuleScope O365Toolkit.Core {
            Mock Get-MgContext {
                throw 'SessionNotInitialized'
            }

            Mock Write-ToolkitLog {}
            Mock Disconnect-MgGraph {}

            $result =
                Disconnect-ToolkitGraph `
                    -Config $testConfig `
                    -PassThru

            $result.Success | Should -BeTrue
            $result.WasConnected | Should -BeFalse

            Should -Invoke Disconnect-MgGraph -Times 0
        } -Parameters @{
            testConfig = $script:testConfig
        }
    }

    It 'disconnects an active session and suppresses SDK output' {
        InModuleScope O365Toolkit.Core {
            Mock Get-MgContext {
                $validContext
            }

            Mock Disconnect-MgGraph {
                $validContext
            }

            Mock Write-ToolkitLog {}

            $result =
                Disconnect-ToolkitGraph `
                    -Config $testConfig `
                    -PassThru

            @($result).Count | Should -Be 1
            $result.Success | Should -BeTrue
            $result.WasConnected | Should -BeTrue
            $result.PreviousAccount |
                Should -Be 'admin@contoso.com'

            Should -Invoke Disconnect-MgGraph -Times 1
        } -Parameters @{
            testConfig   = $script:testConfig
            validContext = $script:validContext
        }
    }
}
