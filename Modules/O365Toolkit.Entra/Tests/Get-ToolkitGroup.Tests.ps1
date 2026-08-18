BeforeAll {
    function global:Assert-ToolkitGraphConnection { }
    function global:Get-ToolkitGraphUri {
        param([string]$RelativePath, [hashtable]$Config)
        return "https://graph.microsoft.com/$RelativePath"
    }
    function global:Invoke-ToolkitGraphRequest {
        param([string]$Uri, [string]$Method, [switch]$AllPages, [hashtable]$Config)
    }
    $corePsd1  = "$(Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))\Core\O365Toolkit.Core.psd1"
    $entraPsd1 = "$(Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))\Modules\O365Toolkit.Entra\O365Toolkit.Entra.psd1"

    if (-not (Get-Module -Name O365Toolkit.Core)) {
        Import-Module $corePsd1 -Force -ErrorAction Stop
    }
    if (-not (Get-Module -Name O365Toolkit.Entra)) {
        Import-Module $entraPsd1 -Force -ErrorAction Stop
    }
}

Describe "Get-ToolkitGroup" {
    Context "Parameter Validation & Request Building" {
        It "queries groups via Graph endpoint with select parameters" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return @( [PSCustomObject]@{ id = 'grp-001'; displayName = 'Finance-Team' } )
            }
            $groups = Get-ToolkitGroup -DisplayName 'Finance-Team'
            $groups.Count | Should -Be 1
            $groups[0].displayName | Should -Be 'Finance-Team'
        }

        It "queries a single group explicitly by GroupId" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{ id = 'grp-002'; displayName = 'Exec-Board' }
            }
            $group = Get-ToolkitGroup -GroupId 'grp-002'
            $group.displayName | Should -Be 'Exec-Board'
        }
    }
}

