BeforeAll {
    $corePsd1   = "$(Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))\Core\O365Toolkit.Core.psd1"
    if (-not (Test-Path $corePsd1)) {
        $corePsd1 = "$(Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))\Core\O365Toolkit.Core.psd1"
    }
    $intunePsd1 = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath "O365Toolkit.Intune.psd1"

    if (-not (Get-Module -Name O365Toolkit.Core)) {
        Import-Module $corePsd1 -Force -ErrorAction Stop
    }
    if (-not (Get-Module -Name O365Toolkit.Intune)) {
        Import-Module $intunePsd1 -Force -ErrorAction Stop
    }
}

Describe "Get-ToolkitIntuneCompliance" {
    Context "Parameter Validation & Request Building" {
        It "queries device compliance policies via Graph endpoint with default parameters" {
            Mock -ModuleName 'O365Toolkit.Intune' Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id          = 'policy-guid-001'
                        displayName = 'Windows 11 Baseline Compliance'
                        description = 'Enforces secure boot, bitlocker, and password complexity.'
                    }
                )
            }

            $policies = Get-ToolkitIntuneCompliance
            $policies.Count | Should -Be 1
            $policies[0].displayName | Should -Be 'Windows 11 Baseline Compliance'
        }

        It "queries a single compliance policy explicitly by PolicyId" {
            Mock -ModuleName 'O365Toolkit.Intune' Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id          = 'policy-guid-002'
                    displayName = 'iOS Security Compliance Policy'
                }
            }

            $policy = Get-ToolkitIntuneCompliance -PolicyId 'policy-guid-002'
            $policy.displayName | Should -Be 'iOS Security Compliance Policy'
        }
    }
}
