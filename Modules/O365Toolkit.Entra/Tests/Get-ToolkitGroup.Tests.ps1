BeforeAll {
    Import-Module "$PSScriptRoot\..\..\..\Core\O365Toolkit.Core.psd1" -Force
    Import-Module "$PSScriptRoot\..\O365Toolkit.Entra.psd1" -Force
}

Describe 'Get-ToolkitGroup' {
    Context 'Parameter Validation & Request Building' {
        It 'queries groups via Graph endpoint with select parameters' {
            Mock Invoke-ToolkitGraphRequest {
                return [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            id              = 'group-guid-1'
                            displayName     = 'Cloud Admins'
                            description     = 'Global Cloud Administrators'
                            groupTypes      = @()
                            mailEnabled     = $false
                            securityEnabled = $true
                        }
                    )
                }
            } -ModuleName 'O365Toolkit.Entra'

            $dummyConfig = [pscustomobject]@{ TenantId = 'mock-tenant' }
            $groups = Get-ToolkitGroup -DisplayName 'Cloud Admins' -Config $dummyConfig
            $groups.Count | Should -Be 1
            $groups[0].displayName | Should -Be 'Cloud Admins'
            $groups[0].id | Should -Be 'group-guid-1'
        }

        It 'queries a single group explicitly by GroupId' {
            Mock Invoke-ToolkitGraphRequest {
                return [pscustomobject]@{
                    id              = 'group-guid-2'
                    displayName     = 'Engineering Team'
                    description     = 'Engineering department group'
                    groupTypes      = @('Unified')
                    mailEnabled     = $true
                    securityEnabled = $true
                }
            } -ModuleName 'O365Toolkit.Entra'

            $dummyConfig = [pscustomobject]@{ TenantId = 'mock-tenant' }
            $group = Get-ToolkitGroup -GroupId 'group-guid-2' -Config $dummyConfig
            $group.id | Should -Be 'group-guid-2'
            $group.displayName | Should -Be 'Engineering Team'
        }
    }
}
