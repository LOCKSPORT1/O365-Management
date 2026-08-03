@{
    RootModule = 'O365Toolkit.Entra.psm1'

    ModuleVersion = '0.1.0'
    GUID = '72ec25a4-7dcb-4ed6-83e7-68f66c0b3f54'

    Author = 'Joshua Christy'

    CompanyName = 'Community'

    Copyright = '(c) 2026 Joshua Christy. All rights reserved.'

    Description = 'Microsoft Entra ID user, group, device, and licensing commands for the O365 Management Toolkit.'

    PowerShellVersion = '7.2'

    FunctionsToExport = @(
        'Get-ToolkitUser'
        'Get-ToolkitGroup'
    ) 

    CmdletsToExport = @()

    VariablesToExport = @()

    AliasesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags = @(
                'Microsoft365'
                'Entra'
                'AzureAD'
                'Users'
                'Graph'
                'Automation'
            )

            ProjectUri = 'https://github.com/LOCKSPORT1/O365-Management'
        }
    }
}



