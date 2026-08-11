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

Describe "Get-ToolkitSharedMailbox" {
    Context "Parameter Validation & Request Building" {
        It "queries shared mailboxes with default parameters" {
            Mock -ModuleName 'O365Toolkit.Exchange' Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id                = 'mbx-guid-001'
                        displayName       = 'Support Shared Mailbox'
                        userPrincipalName = 'support@domain.com'
                        mailboxSettings   = @{ userType = 'Shared' }
                    }
                )
            }

            $mailboxes = Get-ToolkitSharedMailbox
            $mailboxes.Count | Should -Be 1
            $mailboxes[0].userPrincipalName | Should -Be 'support@domain.com'
        }
    }
}
