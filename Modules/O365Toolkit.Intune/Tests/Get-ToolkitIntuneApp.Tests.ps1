BeforeAll {
    $corePsd1   = "C:\Users\jchri\Documents\GitHub\O365-Management\Core\O365Toolkit.Core.psd1"
    if (-not (Test-Path $corePsd1)) {
        $corePsd1 = "C:\Users\jchristy\Documents\GitHub\O365-Management\Core\O365Toolkit.Core.psd1"
    }
    $intunePsd1 = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath "O365Toolkit.Intune.psd1"

    if (-not (Get-Module -Name O365Toolkit.Core)) {
        Import-Module $corePsd1 -Force -ErrorAction Stop
    }
    if (-not (Get-Module -Name O365Toolkit.Intune)) {
        Import-Module $intunePsd1 -Force -ErrorAction Stop
    }
}

Describe "Get-ToolkitIntuneApp" {
    Context "Parameter Validation & Request Building" {
        It "queries mobile apps via Graph endpoint with default parameters" {
            Mock -ModuleName 'O365Toolkit.Intune' Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id          = 'app-guid-001'
                        displayName = 'Microsoft 365 Apps for Enterprise'
                        publisher   = 'Microsoft'
                        '@odata.type' = '#microsoft.graph.win32LobApp'
                    }
                )
            }

            $apps = Get-ToolkitIntuneApp
            $apps.Count | Should -Be 1
            $apps[0].displayName | Should -Be 'Microsoft 365 Apps for Enterprise'
        }
    }
}
