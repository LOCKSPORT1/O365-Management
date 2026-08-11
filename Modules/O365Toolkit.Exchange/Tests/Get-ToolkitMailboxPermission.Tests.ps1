BeforeAll {
    $corePsd1     = "C:\Users\jchri\Documents\GitHub\O365-Management\Core\O365Toolkit.Core.psd1"
    if (-not (Test-Path $corePsd1)) {
        $corePsd1 = "C:\Users\jchristy\Documents\GitHub\O365-Management\Core\O365Toolkit.Core.psd1"
    }
    $exchangePsd1 = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath "O365Toolkit.Exchange.psd1"

    if (-not (Get-Module -Name O365Toolkit.Core)) {
        Import-Module $corePsd1 -Force -ErrorAction Stop
    }
    if (-not (Get-Module -Name O365Toolkit.Exchange)) {
        Import-Module $exchangePsd1 -Force -ErrorAction Stop
    }
}

Describe "Get-ToolkitMailboxPermission" {
    Context "Parameter Validation & Request Building" {
        It "queries mailbox delegate permissions for a given identity" {
            Mock -ModuleName 'O365Toolkit.Exchange' Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id                = 'mbx-guid-001'
                    userPrincipalName = 'finance@domain.com'
                }
            }

            $perms = Get-ToolkitMailboxPermission -Identity 'finance@domain.com'
            $perms.Count | Should -BeGreaterThan 0
            $perms[0].Identity | Should -Be 'finance@domain.com'
        }

        It "filters permissions by specific PermissionType" {
            Mock -ModuleName 'O365Toolkit.Exchange' Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id                = 'mbx-guid-001'
                    userPrincipalName = 'finance@domain.com'
                }
            }

            $perms = Get-ToolkitMailboxPermission -Identity 'finance@domain.com' -PermissionType 'SendAs'
            $perms.AccessRights | Should -Contain 'SendAs'
        }
    }
}
