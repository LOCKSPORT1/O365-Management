@{
    RootModule = 'O365Toolkit.NotebookLM.psm1'

    ModuleVersion = '0.1.0'

    GUID = '9492d28a-f11a-42b1-a831-a4e26800d144'

    Author = 'Joshua Christy'

    CompanyName = 'Community'

    Copyright = '(c) 2026 Joshua Christy. All rights reserved.'

    Description = 'Private NotebookLM knowledge-export framework for the O365 Management Toolkit.'

    PowerShellVersion = '7.2'

    FunctionsToExport = @(
        'New-ToolkitNotebookExport'
    )

    CmdletsToExport = @()

    VariablesToExport = @()

    AliasesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags = @(
                'NotebookLM'
                'Documentation'
                'KnowledgeBase'
                'PowerShell'
                'Microsoft365'
            )

            ProjectUri = 'https://github.com/LOCKSPORT1/O365-Management'
        }
    }
}