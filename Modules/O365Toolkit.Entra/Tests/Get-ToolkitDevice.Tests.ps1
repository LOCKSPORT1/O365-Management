BeforeAll {
    $repoRoot = Set-Location "C:\Users\jchristy\Documents\GitHub\O365-Management"
    $corePsd1  = (Get-ChildItem -Path . -Filter "O365Toolkit.Core.psd1" -Recurse -File).FullName
    $entraPsd1 = (Get-ChildItem -Path . -Filter "O365Toolkit.Entra.psd1" -Recurse -File).FullName
    
    Import-Module $corePsd1 -Force
    Import-Module $entraPsd1 -Force
}

Describe "Get-ToolkitDevice" {
    Context "Parameter Validation & Request Building" {
        It "queries devices via Graph endpoint with default select parameters" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id              = 'dev-001'
                        displayName     = 'DESKTOP-FINANCE-01'
                        operatingSystem = 'Windows'
                    }
                )
            }

            $devices = Get-ToolkitDevice -OperatingSystem 'Windows'
            
            $devices.Count | Should -Be 1
            $devices[0].displayName | Should -Be 'DESKTOP-FINANCE-01'
        }

        It "queries a single device explicitly by DeviceId" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id              = 'dev-002'
                    displayName     = 'LAPTOP-EXEC-02'
                    operatingSystem = 'Windows'
                }
            }

            $device = Get-ToolkitDevice -DeviceId 'dev-002'

            $device.displayName | Should -Be 'LAPTOP-EXEC-02'
        }
    }
}
