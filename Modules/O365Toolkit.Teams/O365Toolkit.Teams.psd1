@{
    RootModule           = 'O365Toolkit.Teams.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '5a82e70e-3b2d-41fb-a87f-9b1626f8cb20'
    Author               = 'Automation Team'
    CompanyName          = 'LOCKSPORT1'
    Copyright            = '(c) LOCKSPORT1. All rights reserved.'
    Description          = 'Neutral Microsoft Teams administration module for O365-Management.'
    PowerShellVersion    = '7.2'
    FunctionsToExport    = @(
        'Get-ToolkitTeam'
        'Get-ToolkitTeamChannel'
        'Get-ToolkitTeamUser'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('Microsoft365', 'Teams', 'MSGraph', 'Automation')
        }
    }
}