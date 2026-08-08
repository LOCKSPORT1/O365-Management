@{
    RootModule = 'O365Toolkit.Exchange.psm1'
    ModuleVersion = '0.1.0'
    GUID = '83f4129b-8c41-4712-984e-1f5a98e12345'
    Author = 'Joshua Christy'
    CompanyName = 'Community'
    Copyright = '(c) 2026 Joshua Christy. All rights reserved.'
    Description = 'Exchange Online shared mailbox, delegation, and reporting wrappers for the O365 Management Toolkit.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('Get-ToolkitMessageTrace', 
        'Get-ToolkitSharedMailbox',
        'Get-ToolkitMailboxPermission'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Microsoft365', 'Exchange', 'ExchangeOnline', 'Mailboxes', 'Automation')
            ProjectUri = 'https://github.com/LOCKSPORT1/O365-Management'
        }
    }
}

