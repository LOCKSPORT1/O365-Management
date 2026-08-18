BeforeAll {
    function global:Assert-ToolkitGraphConnection { }
    function global:Get-ToolkitGraphUri {
        param([string]$RelativePath, [hashtable]$Config)
        return "https://graph.microsoft.com/$RelativePath"
    }
    function global:Invoke-ToolkitGraphRequest {
        param([string]$Uri, [string]$Method, [switch]$AllPages, [hashtable]$Config)
    }
    $corePsd1  = "C:\Users\jchristy\Documents\GitHub\O365-Management\Core\O365Toolkit.Core.psd1"
    $entraPsd1 = "C:\Users\jchristy\Documents\GitHub\O365-Management\Modules\O365Toolkit.Entra\O365Toolkit.Entra.psd1"

    if (-not (Get-Module -Name O365Toolkit.Core)) {
        Import-Module $corePsd1 -Force -ErrorAction Stop
    }
    if (-not (Get-Module -Name O365Toolkit.Entra)) {
        Import-Module $entraPsd1 -Force -ErrorAction Stop
    }
}

Describe "Get-ToolkitUser" {
    It "retrieves one user by UPN" {
        Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
            return [PSCustomObject]@{ id = 'usr-001'; userPrincipalName = 'user@domain.com' }
        }
        $u = Get-ToolkitUser -UserPrincipalName 'user@domain.com'
        $u.userPrincipalName | Should -Be 'user@domain.com'
    }

    It "retrieves all users using paging" {
        Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
            return @( [PSCustomObject]@{ id = 'usr-001' }, [PSCustomObject]@{ id = 'usr-002' } )
        }
        $u = Get-ToolkitUser -All
        $u.Count | Should -Be 2
    }

    It "filters users by department" {
        Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
            return @( [PSCustomObject]@{ id = 'usr-001'; department = 'IT' } )
        }
        $u = Get-ToolkitUser -Department 'IT'
        $u.department | Should -Be 'IT'
    }

    It "filters licensed users" {
        Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
            return @( [PSCustomObject]@{ id = 'usr-001'; assignedLicenses = @('lic1') } )
        }
        $u = Get-ToolkitUser -HasLicenses
        $u.assignedLicenses.Count | Should -Be 1
    }

    It "returns metadata for a UPN lookup with PassThru" {
        Mock -ModuleName 'O365Toolkit.Entra' Invoke-ToolkitGraphRequest {
            return [PSCustomObject]@{ id = 'usr-001'; userPrincipalName = 'user@domain.com' }
        }
        $u = Get-ToolkitUser -UserPrincipalName 'user@domain.com'
        $u.id | Should -Be 'usr-001'
    }
}

