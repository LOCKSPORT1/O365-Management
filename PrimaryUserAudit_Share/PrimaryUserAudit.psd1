@{
    RootModule        = 'PrimaryUserAudit.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = '7b6f17f5-7646-4c13-a863-d356e1547851'

    Author            = 'Joshua Christy'
    CompanyName       = 'Community'
    Copyright         = '(c) 2026 Joshua Christy. All rights reserved.'

    Description       = 'Audits Microsoft Intune primary-user assignments using Microsoft Entra sign-in evidence and confidence-based recommendations.'

    PowerShellVersion = '7.2'

    RequiredModules   = @(
        @{
            ModuleName    = 'Microsoft.Graph.Authentication'
            ModuleVersion = '2.0.0'
        }
    )

    FunctionsToExport = @(
    'Invoke-PrimaryUserAudit',
    'Invoke-PrimaryUserRemediation',
    'Invoke-PrimaryUserRollback'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @(
                'Microsoft365'
                'MicrosoftGraph'
                'Intune'
                'Entra'
                'PowerShell'
                'Automation'
                'PrimaryUser'
            )

            ProjectUri = 'https://github.com/LOCKSPORT1/O365-Management'

            ReleaseNotes = @'
Version 2.0.0
- Added modular private and public function architecture
- Added Microsoft Graph authentication helper
- Added retry and pagination support
- Added managed Windows device retrieval
- Added Entra sign-in evidence collection
- Added confidence-based primary-user recommendations
- Added CSV report exports
- Added end-to-end audit command
'@
        }
    }
}