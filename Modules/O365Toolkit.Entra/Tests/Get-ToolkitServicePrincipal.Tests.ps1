BeforeAll {
    function global:Assert-ToolkitGraphConnection { }
    function global:Get-ToolkitGraphUri {
        param([string]$RelativePath, [hashtable]$Config)
        return "https://graph.microsoft.com/$RelativePath"
    }
    function global:Invoke-ToolkitGraphRequest {
        param([string]$Uri, [string]$Method, [switch]$AllPages, [hashtable]$Config)
    }
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

Describe "Get-ToolkitServicePrincipal" {
    Context "Parameter Validation & Request Building" {
        It "queries service principals via Graph endpoint with default parameters" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id                   = 'sp-guid-001'
                        appId                = 'app-guid-001'
                        displayName          = 'Finance Automation App'
                        servicePrincipalType = 'Application'
                        accountEnabled       = $true
                    }
                )
            }

            $sps = Get-ToolkitServicePrincipal
            $sps.Count | Should -Be 1
            $sps[0].displayName | Should -Be 'Finance Automation App'
        }

        It "queries a single service principal explicitly by ServicePrincipalId" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id             = 'sp-guid-002'
                    appId          = 'app-guid-002'
                    displayName    = 'HR Sync Service'
                    accountEnabled = $true
                }
            }

            $sp = Get-ToolkitServicePrincipal -ServicePrincipalId 'sp-guid-002'
            $sp.displayName | Should -Be 'HR Sync Service'
        }

        It "queries a single service principal explicitly by AppId" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id             = 'sp-guid-003'
                        appId          = '11111111-2222-3333-4444-555555555555'
                        displayName    = 'Target App by ClientId'
                        accountEnabled = $true
                    }
                )
            }

            $sp = Get-ToolkitServicePrincipal -AppId '11111111-2222-3333-4444-555555555555'
            $sp[0].displayName | Should -Be 'Target App by ClientId'
        }
    }
}
