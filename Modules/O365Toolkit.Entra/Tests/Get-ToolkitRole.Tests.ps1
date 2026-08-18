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
    if (-not (Test-Path $corePsd1)) {
        $corePsd1 = "$(Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))\Core\O365Toolkit.Core.psd1"
    }
    $entraPsd1 = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath "O365Toolkit.Entra.psd1"

    if (-not (Get-Module -Name O365Toolkit.Core)) {
        Import-Module $corePsd1 -Force -ErrorAction Stop
    }
    if (-not (Get-Module -Name O365Toolkit.Entra)) {
        Import-Module $entraPsd1 -Force -ErrorAction Stop
    }
}

Describe "Get-ToolkitRole" {
    Context "Parameter Validation & Request Building" {
        It "queries active directory roles with default parameters" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id             = 'role-guid-001'
                        displayName    = 'Global Administrator'
                        description    = 'Can manage all aspects of Azure AD and Microsoft 365 services.'
                        roleTemplateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                    }
                )
            }

            $roles = Get-ToolkitRole
            $roles.Count | Should -Be 1
            $roles[0].displayName | Should -Be 'Global Administrator'
        }

        It "queries a single directory role explicitly by RoleId" {
            Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id             = 'role-guid-002'
                    displayName    = 'Helpdesk Administrator'
                    roleTemplateId = 'fee87c44-b258-450f-90e9-b684346e9ce2'
                }
            }

            $role = Get-ToolkitRole -RoleId 'role-guid-002'
            $role.displayName | Should -Be 'Helpdesk Administrator'
        }
    }
}
