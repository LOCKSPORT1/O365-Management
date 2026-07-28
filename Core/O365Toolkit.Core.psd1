@{
    RootModule =
        'O365Toolkit.Core.psm1'

    ModuleVersion =
        '0.1.0'

    GUID =
        '8c9f60ad-0677-4af0-bd0d-f73881406442'

    Author =
        'Joshua Christy'

    CompanyName =
        'Community'

    Copyright =
        '(c) 2026 Joshua Christy. All rights reserved.'

    Description =
        'Shared configuration, logging, authentication, reporting, and Microsoft Graph helpers for the O365 Management Toolkit.'

    PowerShellVersion =
        '7.2'

    FunctionsToExport =
        @(
            'Read-ToolkitConfig'
        )

    CmdletsToExport =
        @()

    VariablesToExport =
        @()

    AliasesToExport =
        @()

    PrivateData = @{
        PSData = @{
            Tags =
                @(
                    'Microsoft365'
                    'Entra'
                    'Intune'
                    'Exchange'
                    'Graph'
                    'Automation'
                )

            ProjectUri =
                'https://github.com/LOCKSPORT1/O365-Management'
        }
    }
}
