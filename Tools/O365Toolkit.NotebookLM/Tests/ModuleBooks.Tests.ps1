$moduleManifestPath = (
    Resolve-Path `
        -LiteralPath (
            Join-Path `
                -Path (
                    Split-Path `
                        -Path $PSCommandPath `
                        -Parent
                ) `
                -ChildPath '..\O365Toolkit.NotebookLM.psd1'
        ) `
        -ErrorAction Stop
).Path

$loadedModule = Get-Module `
    -Name O365Toolkit.NotebookLM `
    -ErrorAction SilentlyContinue

if ($null -eq $loadedModule) {
    Import-Module `
        -Name $moduleManifestPath `
        -Force `
        -ErrorAction Stop
}

Describe 'New-ToolkitModuleBooks' {
    InModuleScope O365Toolkit.NotebookLM {
        It 'creates grouped Markdown books from safe inventory files' {
            $repositoryPath = Join-Path `
                -Path $TestDrive `
                -ChildPath 'Repository'

            $outputPath = Join-Path `
                -Path $TestDrive `
                -ChildPath 'Books'

            $pathsToCreate = @(
                'Core'
                'Modules\O365Toolkit.Entra'
                'Tools\O365Toolkit.NotebookLM'
                'docs'
            )

            foreach ($relativeDirectory in $pathsToCreate) {
                New-Item `
                    -Path (
                        Join-Path `
                            -Path $repositoryPath `
                            -ChildPath $relativeDirectory
                    ) `
                    -ItemType Directory `
                    -Force |
                    Out-Null
            }

            $coreFile = Join-Path `
                -Path $repositoryPath `
                -ChildPath 'Core\Connect-Test.ps1'

            $entraFile = Join-Path `
                -Path $repositoryPath `
                -ChildPath 'Modules\O365Toolkit.Entra\Get-TestUser.ps1'

            $compilerFile = Join-Path `
                -Path $repositoryPath `
                -ChildPath 'Tools\O365Toolkit.NotebookLM\Compiler.ps1'

            $additionalFile = Join-Path `
                -Path $repositoryPath `
                -ChildPath 'docs\README.md'

            Set-Content `
                -LiteralPath $coreFile `
                -Value 'function Connect-Test { }' `
                -Encoding utf8

            Set-Content `
                -LiteralPath $entraFile `
                -Value 'function Get-TestUser { }' `
                -Encoding utf8

            Set-Content `
                -LiteralPath $compilerFile `
                -Value 'function Invoke-TestCompiler { }' `
                -Encoding utf8

            Set-Content `
                -LiteralPath $additionalFile `
                -Value '# Test documentation' `
                -Encoding utf8

            $inventory = [pscustomobject]@{
                RepositoryPath = $repositoryPath
                FileCount      = 4
                IncludedFiles  = @(
                    [pscustomobject]@{
                        Name          = 'Connect-Test.ps1'
                        FullName      = $coreFile
                        RelativePath  = 'Core\Connect-Test.ps1'
                        Extension     = '.ps1'
                        Category      = 'PowerShell Script'
                        Length        = 25
                        LastWriteTime = Get-Date
                    }
                    [pscustomobject]@{
                        Name          = 'Get-TestUser.ps1'
                        FullName      = $entraFile
                        RelativePath  = 'Modules\O365Toolkit.Entra\Get-TestUser.ps1'
                        Extension     = '.ps1'
                        Category      = 'PowerShell Script'
                        Length        = 26
                        LastWriteTime = Get-Date
                    }
                    [pscustomobject]@{
                        Name          = 'Compiler.ps1'
                        FullName      = $compilerFile
                        RelativePath  = 'Tools\O365Toolkit.NotebookLM\Compiler.ps1'
                        Extension     = '.ps1'
                        Category      = 'PowerShell Script'
                        Length        = 33
                        LastWriteTime = Get-Date
                    }
                    [pscustomobject]@{
                        Name          = 'README.md'
                        FullName      = $additionalFile
                        RelativePath  = 'docs\README.md'
                        Extension     = '.md'
                        Category      = 'Markdown Documentation'
                        Length        = 20
                        LastWriteTime = Get-Date
                    }
                )
            }

            $result = New-ToolkitModuleBooks `
                -Inventory $inventory `
                -OutputPath $outputPath

            $result.Success |
                Should -BeTrue

            $result.SourceCount |
                Should -Be 4

            $result.BookCount |
                Should -Be 4

            $expectedBooks = @(
                '05_Core_Module_Source.md'
                '06_O365Toolkit_Entra_Module_Source.md'
                '07_NotebookLM_Compiler_Source.md'
                '11_Additional_Project_Source.md'
            )

            foreach ($bookName in $expectedBooks) {
                Test-Path `
                    -LiteralPath (
                        Join-Path `
                            -Path $outputPath `
                            -ChildPath $bookName
                    ) |
                    Should -BeTrue
            }

            $coreBook = Get-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $outputPath `
                        -ChildPath '05_Core_Module_Source.md'
                ) `
                -Raw

            $coreBook |
                Should -Match 'Core\\Connect-Test\.ps1'

            $coreBook |
                Should -Match 'function Connect-Test'

            $entraBook = Get-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $outputPath `
                        -ChildPath '06_O365Toolkit_Entra_Module_Source.md'
                ) `
                -Raw

            $entraBook |
                Should -Match 'Get-TestUser'

            $compilerBook = Get-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $outputPath `
                        -ChildPath '07_NotebookLM_Compiler_Source.md'
                ) `
                -Raw

            $compilerBook |
                Should -Match 'Invoke-TestCompiler'
        }

        It 'excludes unsupported inventory extensions' {
            $sourcePath = Join-Path `
                -Path $TestDrive `
                -ChildPath 'Unsupported.exe'

            Set-Content `
                -LiteralPath $sourcePath `
                -Value 'binary placeholder' `
                -Encoding utf8

            $inventory = [pscustomobject]@{
                RepositoryPath = $TestDrive
                FileCount      = 1
                IncludedFiles  = @(
                    [pscustomobject]@{
                        Name          = 'Unsupported.exe'
                        FullName      = $sourcePath
                        RelativePath  = 'Unsupported.exe'
                        Extension     = '.exe'
                        Category      = 'Other'
                        Length        = 18
                        LastWriteTime = Get-Date
                    }
                )
            }

            $outputPath = Join-Path `
                -Path $TestDrive `
                -ChildPath 'UnsupportedBooks'

            $result = New-ToolkitModuleBooks `
                -Inventory $inventory `
                -OutputPath $outputPath

            $result.Success |
                Should -BeTrue

            $result.SourceCount |
                Should -Be 0

            $result.BookCount |
                Should -Be 0
        }
    }
}
