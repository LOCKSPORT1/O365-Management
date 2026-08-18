@{
    RootModule           = 'O365Toolkit.SharePoint.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '3b2d1840-7e1a-4d7a-8f0a-42c688d01199'
    Author               = 'Automation Team'
    CompanyName          = 'LOCKSPORT1'
    Copyright            = '(c) LOCKSPORT1. All rights reserved.'
    Description          = 'Neutral SharePoint Online administration and storage reporting module for O365-Management.'
    PowerShellVersion    = '7.2'
    FunctionsToExport    = @(
        'Get-ToolkitSharePointSite'
        'Get-ToolkitSharePointUsage'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('Microsoft365', 'SharePoint', 'Storage', 'MSGraph', 'Automation')
        }
    }
}