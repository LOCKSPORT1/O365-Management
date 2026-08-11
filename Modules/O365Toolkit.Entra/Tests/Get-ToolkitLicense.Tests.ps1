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

Describe "Get-ToolkitLicense" {
    Context "Parameter Validation & Request Building" {
        It "queries tenant subscribed SKUs with default parameters" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id            = 'sku-guid-001'
                        skuPartNumber = 'ENTERPRISEPACK'
                        consumedUnits = 45
                        prepaidUnits  = @{ enabled = 100 }
                    }
                )
            }

            $licenses = Get-ToolkitLicense
            $licenses.Count | Should -Be 1
            $licenses[0].skuPartNumber | Should -Be 'ENTERPRISEPACK'
            $licenses[0].consumedUnits | Should -Be 45
        }

        It "queries licenses filtered by SkuPartNumber" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id            = 'sku-guid-002'
                    skuPartNumber = 'SPE_E5'
                    consumedUnits = 10
                }
            }

            $license = Get-ToolkitLicense -SkuPartNumber 'SPE_E5'
            $license.skuPartNumber | Should -Be 'SPE_E5'
        }
    }
}
