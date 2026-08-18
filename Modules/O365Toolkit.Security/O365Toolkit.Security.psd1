@{
    RootModule           = 'O365Toolkit.Security.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '9f37c35e-4f1a-4d7a-b50a-e24c688d0114'
    Author               = 'Automation Team'
    CompanyName          = 'LOCKSPORT1'
    Copyright            = '(c) LOCKSPORT1. All rights reserved.'
    Description          = 'Neutral Microsoft 365 Security & Governance administration module for O365-Management.'
    PowerShellVersion    = '7.2'
    FunctionsToExport    = @(
        'Get-ToolkitConditionalAccessPolicy'
        'Get-ToolkitAuditLogEntry'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('Microsoft365', 'Security', 'ConditionalAccess', 'AuditLogs', 'MSGraph', 'Automation')
        }
    }
}