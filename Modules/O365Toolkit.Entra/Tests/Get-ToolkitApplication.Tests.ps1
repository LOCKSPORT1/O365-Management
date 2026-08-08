BeforeAll {
    $corePsd1  = "C:\Users\jchri\Documents\GitHub\O365-Management\Core\O365Toolkit.Core.psd1"
    if (-not (Test-Path $corePsd1)) {
        $corePsd1 = "C:\Users\jchristy\Documents\GitHub\O365-Management\Core\O365Toolkit.Core.psd1"
    }
    $entraPsd1 = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath "O365Toolkit.Entra.psd1"

    if (-not (Get-Module -Name O365Toolkit.Core)) {
        Import-Module $corePsd1 -Force -ErrorAction Stop
    }
    if (-not (Get-Module -Name O365Toolkit.Entra)) {
        Import-Module $entraPsd1 -Force -ErrorAction Stop
    }
}

Describe "Get-ToolkitApplication" {
    Context "Parameter Validation & Request Building" {
        It "queries application registrations via Graph endpoint with default parameters" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id          = 'app-guid-001'
                        appId       = 'client-guid-001'
                        displayName = 'Custom Reporting App'
                    }
                )
            }

            $apps = Get-ToolkitApplication
            $apps.Count | Should -Be 1
            $apps[0].displayName | Should -Be 'Custom Reporting App'
        }

        It "queries a single application explicitly by ApplicationId" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id          = 'app-guid-002'
                    appId       = 'client-guid-002'
                    displayName = 'Single App Registration'
                }
            }

            $app = Get-ToolkitApplication -ApplicationId 'app-guid-002'
            $app.displayName | Should -Be 'Single App Registration'
        }

        It "queries an application explicitly by AppId (ClientId)" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id          = 'app-guid-003'
                        appId       = '99999999-8888-7777-6666-555555555555'
                        displayName = 'App Found By ClientId'
                    }
                )
            }

            $app = Get-ToolkitApplication -AppId '99999999-8888-7777-6666-555555555555'
            $app[0].displayName | Should -Be 'App Found By ClientId'
        }
    }
}