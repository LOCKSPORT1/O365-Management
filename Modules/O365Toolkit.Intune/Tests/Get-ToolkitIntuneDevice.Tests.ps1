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

Describe "Get-ToolkitIntuneDevice" {
    Context "Parameter Validation & Request Building" {
        It "queries managed devices via Graph endpoint with default parameters" {
            Mock -ModuleName 'O365Toolkit.Intune' Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id              = 'dev-guid-001'
                        deviceName      = 'WS-LAPTOP-01'
                        operatingSystem = 'Windows'
                        complianceState = 'compliant'
                    }
                )
            }

            $devices = Get-ToolkitIntuneDevice
            $devices.Count | Should -Be 1
            $devices[0].deviceName | Should -Be 'WS-LAPTOP-01'
        }
    }
}
