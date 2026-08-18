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

Describe "Get-ToolkitRoleMember" {
    Context "Parameter Validation & Request Building" {
        It "queries members assigned to a specific directory role ID" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id                = 'usr-guid-001'
                        displayName       = 'Jane Admin'
                        userPrincipalName = 'jane.admin@domain.com'
                    }
                )
            }

            $members = Get-ToolkitRoleMember -RoleId 'role-guid-001'
            $members.Count | Should -Be 1
            $members[0].userPrincipalName | Should -Be 'jane.admin@domain.com'
        }
    }
}
