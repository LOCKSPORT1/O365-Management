@{
    RootModule = 'O365Toolkit.Intune.psm1'
    ModuleVersion = '0.1.0'
    GUID = '94e5230c-9d12-4823-895f-2a6b09f23456'
    Author = 'Joshua Christy'
    CompanyName = 'Community'
    Copyright = '(c) 2026 Joshua Christy. All rights reserved.'
    Description = 'Microsoft Intune device management, compliance tracking, and configuration reporting wrappers for the O365 Management Toolkit.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-ToolkitIntuneDevice',
        'Get-ToolkitIntuneCompliance',
        'Get-ToolkitIntuneApp'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Microsoft365', 'Intune', 'DeviceManagement', 'Endpoint', 'Automation')
            ProjectUri = 'https://github.com/LOCKSPORT1/O365-Management'
        }
    }
}
