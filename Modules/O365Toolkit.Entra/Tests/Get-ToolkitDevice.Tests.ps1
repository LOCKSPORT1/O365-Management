BeforeAll {
    $corePsd1  = "C:\Users\jchristy\Documents\GitHub\O365-Management\Core\O365Toolkit.Core.psd1"
    $entraPsd1 = "C:\Users\jchristy\Documents\GitHub\O365-Management\Modules\O365Toolkit.Entra\O365Toolkit.Entra.psd1"

    if (-not (Get-Module -Name O365Toolkit.Core)) {
        Import-Module $corePsd1 -Force -ErrorAction Stop
    }
    if (-not (Get-Module -Name O365Toolkit.Entra)) {
        Import-Module $entraPsd1 -Force -ErrorAction Stop
    }
}

Describe "Get-ToolkitDevice" {
    Context "Parameter Validation & Request Building" {
        It "queries devices via Graph endpoint with default select parameters" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return @( [PSCustomObject]@{ id = 'dev-001'; displayName = 'DESKTOP-FINANCE-01'; operatingSystem = 'Windows' } )
            }
            $devices = Get-ToolkitDevice -OperatingSystem 'Windows'
            $devices.Count | Should -Be 1
            $devices[0].displayName | Should -Be 'DESKTOP-FINANCE-01'
        }

        It "queries a single device explicitly by DeviceId" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{ id = 'dev-002'; displayName = 'LAPTOP-EXEC-02'; operatingSystem = 'Windows' }
            }
            $device = Get-ToolkitDevice -DeviceId 'dev-002'
            $device.displayName | Should -Be 'LAPTOP-EXEC-02'
        }
    }
}
