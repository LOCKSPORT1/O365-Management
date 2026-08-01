$moduleManifestPath = Join-Path `
    -Path (
        Split-Path `
            -Path $PSScriptRoot `
            -Parent
    ) `
    -ChildPath 'O365Toolkit.NotebookLM.psd1'

$moduleManifestPath = (
    Resolve-Path `
        -LiteralPath $moduleManifestPath `
        -ErrorAction Stop
).Path

Get-Module O365Toolkit.NotebookLM -All |
    Remove-Module `
        -Force `
        -ErrorAction SilentlyContinue

Import-Module `
    -Name $moduleManifestPath `
    -Force `
    -ErrorAction Stop
Describe 'O365Toolkit.NotebookLM module' {
    It 'has a valid module manifest' {
        $loadedModule = Get-Module `
            -Name O365Toolkit.NotebookLM `
            -ErrorAction Stop

        $manifestPath = Join-Path `
            -Path (
                Split-Path `
                    -Path $loadedModule.Path `
                    -Parent
            ) `
            -ChildPath 'O365Toolkit.NotebookLM.psd1'

        Test-Path `
            -LiteralPath $manifestPath |
            Should -BeTrue

        Test-ModuleManifest `
            -Path $manifestPath `
            -ErrorAction Stop |
            Should -Not -BeNullOrEmpty
    }

    It 'exports New-ToolkitNotebookExport' {
        Get-Command `
            -Name New-ToolkitNotebookExport `
            -Module O365Toolkit.NotebookLM `
            -ErrorAction Stop |
            Should -Not -BeNullOrEmpty
    }

    It 'keeps helper functions private' {
        $helperNames = @(
            'Invoke-ToolkitGitCommand'
            'Get-ToolkitNotebookMarker'
            'Set-ToolkitNotebookMarker'
            'Get-ToolkitNotebookGitSnapshot'
            'Get-ToolkitNotebookRepositoryInventory'
            'Copy-ToolkitNotebookRepositorySnapshot'
            'New-ToolkitNotebookDocuments'
            'New-ToolkitProjectIndex'
            'New-ToolkitFunctionReference'
        )

        foreach ($helperName in $helperNames) {
            Get-Command `
                -Name $helperName `
                -ErrorAction SilentlyContinue |
                Should -BeNullOrEmpty
        }
    }
}

Describe 'NotebookLM private marker helpers' {
    InModuleScope O365Toolkit.NotebookLM {
        BeforeEach {
            $script:testRoot = Join-Path `
                -Path $TestDrive `
                -ChildPath 'PrivateNotebookLM'

            $script:markerPath = Join-Path `
                -Path $script:testRoot `
                -ChildPath 'SESSION_MARKER_PRIVATE.md'
        }

        It 'returns Exists false when the marker does not exist' {
            $result = Get-ToolkitNotebookMarker `
                -MarkerPath $script:markerPath

            $result.Exists |
                Should -BeFalse

            $result.BaselineCommit |
                Should -BeNullOrEmpty
        }

        It 'writes and reads a private marker' {
            $writeResult = Set-ToolkitNotebookMarker `
                -MarkerPath $script:markerPath `
                -ExportVersion 'v0.1' `
                -BaselineCommit 'abc123' `
                -BaselineTag 'entra-v0.1.0' `
                -Branch 'main' `
                -PreviousBaselineCommit 'def456' `
                -NextFeature 'Get-ToolkitGroup'

            $writeResult.Success |
                Should -BeTrue

            Test-Path `
                -LiteralPath $script:markerPath |
                Should -BeTrue

            $readResult = Get-ToolkitNotebookMarker `
                -MarkerPath $script:markerPath

            $readResult.Exists |
                Should -BeTrue

            $readResult.ExportVersion |
                Should -Be 'v0.1'

            $readResult.BaselineCommit |
                Should -Be 'abc123'

            $readResult.BaselineTag |
                Should -Be 'entra-v0.1.0'

            $readResult.Branch |
                Should -Be 'main'

            $readResult.PreviousBaselineCommit |
                Should -Be 'def456'

            $readResult.NextFeature |
                Should -Be 'Get-ToolkitGroup'
        }
    }
}

Describe 'Get-ToolkitNotebookRepositoryInventory' {
    InModuleScope O365Toolkit.NotebookLM {
        BeforeEach {
            $script:repositoryPath = Join-Path `
                -Path $TestDrive `
                -ChildPath 'InventoryRepository'

            $safeDirectories = @(
                'Public'
                'Private'
                'docs'
                'templates'
                'config'
            )

            foreach ($directory in $safeDirectories) {
                New-Item `
                    -Path (
                        Join-Path `
                            -Path $script:repositoryPath `
                            -ChildPath $directory
                    ) `
                    -ItemType Directory `
                    -Force |
                    Out-Null
            }

            $excludedDirectories = @(
                'Reports'
                'Logs'
                'Exports'
            )

            foreach ($directory in $excludedDirectories) {
                New-Item `
                    -Path (
                        Join-Path `
                            -Path $script:repositoryPath `
                            -ChildPath $directory
                    ) `
                    -ItemType Directory `
                    -Force |
                    Out-Null
            }

            Set-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $script:repositoryPath `
                        -ChildPath 'Public\Get-TestItem.ps1'
                ) `
                -Value @'
function Get-TestItem {
    [CmdletBinding()]
    param()

    return 'Test'
}
'@ `
                -Encoding utf8

            Set-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $script:repositoryPath `
                        -ChildPath 'Private\Invoke-TestHelper.ps1'
                ) `
                -Value @'
function Invoke-TestHelper {
    [CmdletBinding()]
    param()

    return $true
}
'@ `
                -Encoding utf8

            Set-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $script:repositoryPath `
                        -ChildPath 'docs\README.md'
                ) `
                -Value '# Test documentation' `
                -Encoding utf8

            Set-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $script:repositoryPath `
                        -ChildPath 'templates\BulkUsers.csv'
                ) `
                -Value 'UserPrincipalName' `
                -Encoding utf8

            Set-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $script:repositoryPath `
                        -ChildPath 'config\toolkit.example.json'
                ) `
                -Value '{"Environment":"Global"}' `
                -Encoding utf8

            Set-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $script:repositoryPath `
                        -ChildPath 'Reports\RealUserReport.csv'
                ) `
                -Value 'User,Device' `
                -Encoding utf8

            Set-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $script:repositoryPath `
                        -ChildPath 'config\tenants.json'
                ) `
                -Value '{"TenantId":"secret"}' `
                -Encoding utf8

            Set-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $script:repositoryPath `
                        -ChildPath 'config\primary-user-audit.json'
                ) `
                -Value '{"LiveConfig":true}' `
                -Encoding utf8

            Set-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $script:repositoryPath `
                        -ChildPath 'Logs\toolkit.log'
                ) `
                -Value 'Sensitive log data' `
                -Encoding utf8

            Set-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $script:repositoryPath `
                        -ChildPath 'Exports\export.txt'
                ) `
                -Value 'Generated export data' `
                -Encoding utf8
        }

        It 'includes safe source, documentation, template, and example files' {
            $result = Get-ToolkitNotebookRepositoryInventory `
                -RepositoryPath $script:repositoryPath

            $relativePaths = @(
                $result.IncludedFiles.RelativePath
            )

            $relativePaths |
                Should -Contain 'Public\Get-TestItem.ps1'

            $relativePaths |
                Should -Contain 'Private\Invoke-TestHelper.ps1'

            $relativePaths |
                Should -Contain 'docs\README.md'

            $relativePaths |
                Should -Contain 'templates\BulkUsers.csv'

            $relativePaths |
                Should -Contain 'config\toolkit.example.json'
        }

        It 'excludes reports, live configs, logs, and generated exports' {
            $result = Get-ToolkitNotebookRepositoryInventory `
                -RepositoryPath $script:repositoryPath

            $relativePaths = @(
                $result.IncludedFiles.RelativePath
            )

            $relativePaths |
                Should -Not -Contain 'Reports\RealUserReport.csv'

            $relativePaths |
                Should -Not -Contain 'config\tenants.json'

            $relativePaths |
                Should -Not -Contain 'config\primary-user-audit.json'

            $relativePaths |
                Should -Not -Contain 'Logs\toolkit.log'

            $relativePaths |
                Should -Not -Contain 'Exports\export.txt'
        }

        It 'only includes CSV files from template folders' {
            Set-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $script:repositoryPath `
                        -ChildPath 'UnsafeData.csv'
                ) `
                -Value 'Real,Data' `
                -Encoding utf8

            $result = Get-ToolkitNotebookRepositoryInventory `
                -RepositoryPath $script:repositoryPath

            $csvFiles = @(
                $result.IncludedFiles |
                Where-Object Extension -eq '.csv'
            )

            $csvFiles.Count |
                Should -Be 1

            $csvFiles[0].RelativePath |
                Should -Be 'templates\BulkUsers.csv'
        }
    }
}

Describe 'Copy-ToolkitNotebookRepositorySnapshot' {
    InModuleScope O365Toolkit.NotebookLM {
        It 'copies every file supplied by the secure inventory' {
            $sourceRoot = Join-Path `
                -Path $TestDrive `
                -ChildPath 'SnapshotSource'

            $destinationRoot = Join-Path `
                -Path $TestDrive `
                -ChildPath 'SnapshotDestination'

            New-Item `
                -Path (
                    Join-Path `
                        -Path $sourceRoot `
                        -ChildPath 'Public'
                ) `
                -ItemType Directory `
                -Force |
                Out-Null

            New-Item `
                -Path (
                    Join-Path `
                        -Path $sourceRoot `
                        -ChildPath 'docs'
                ) `
                -ItemType Directory `
                -Force |
                Out-Null

            $sourceScript = Join-Path `
                -Path $sourceRoot `
                -ChildPath 'Public\Get-Test.ps1'

            $sourceDocument = Join-Path `
                -Path $sourceRoot `
                -ChildPath 'docs\README.md'

            Set-Content `
                -LiteralPath $sourceScript `
                -Value 'function Get-Test { }' `
                -Encoding utf8

            Set-Content `
                -LiteralPath $sourceDocument `
                -Value '# Documentation' `
                -Encoding utf8

            $inventory = [pscustomobject]@{
                RepositoryPath = $sourceRoot
                IncludedFiles  = @(
                    [pscustomobject]@{
                        FullName     = $sourceScript
                        RelativePath = 'Public\Get-Test.ps1'
                    }
                    [pscustomobject]@{
                        FullName     = $sourceDocument
                        RelativePath = 'docs\README.md'
                    }
                )
                FileCount = 2
            }

            $result = Copy-ToolkitNotebookRepositorySnapshot `
                -Inventory $inventory `
                -DestinationPath $destinationRoot

            $result.Success |
                Should -BeTrue

            $result.FileCount |
                Should -Be 2

            Test-Path `
                -LiteralPath (
                    Join-Path `
                        -Path $destinationRoot `
                        -ChildPath 'Public\Get-Test.ps1'
                ) |
                Should -BeTrue

            Test-Path `
                -LiteralPath (
                    Join-Path `
                        -Path $destinationRoot `
                        -ChildPath 'docs\README.md'
                ) |
                Should -BeTrue
        }
    }
}

Describe 'New-ToolkitNotebookDocuments' {
    InModuleScope O365Toolkit.NotebookLM {
        It 'creates the five base NotebookLM source files' {
            $outputPath = Join-Path `
                -Path $TestDrive `
                -ChildPath 'Documents'

            $snapshot = [pscustomobject]@{
                Branch                 = 'main'
                CurrentCommit          = 'abc123'
                LatestTag              = 'entra-v0.1.0'
                PreviousBaselineCommit = 'def456'
                IncrementalRange       = 'def456..abc123'
                IsClean                = $true
                CommitLog              = @(
                    'abc123 | 2026-07-31 | Test commit'
                )
                DiffStat               = @(
                    '1 file changed'
                )
                ChangedFiles           = @(
                    'A Test.ps1'
                )
            }

            $result = New-ToolkitNotebookDocuments `
                -Snapshot $snapshot `
                -OutputPath $outputPath `
                -ExportVersion 'v0.2' `
                -NextFeature 'Get-ToolkitGroup' `
                -TestSummary @'
Total: 69
Passed: 69
Failed: 0
Skipped: 0
'@

            $result.Success |
                Should -BeTrue

            $result.FileCount |
                Should -Be 5

            $expectedFiles = @(
                'Architecture.md'
                'Decisions.md'
                'Development_Timeline.md'
                'NotebookLM_Prompts.txt'
                'O365Toolkit_Master_Guide.md'
            )

            foreach ($fileName in $expectedFiles) {
                Test-Path `
                    -LiteralPath (
                        Join-Path `
                            -Path $outputPath `
                            -ChildPath $fileName
                    ) |
                    Should -BeTrue
            }

            $masterGuide = Get-Content `
                -LiteralPath (
                    Join-Path `
                        -Path $outputPath `
                        -ChildPath 'O365Toolkit_Master_Guide.md'
                ) `
                -Raw

            $masterGuide |
                Should -Match 'Get-ToolkitGroup'

            $masterGuide |
                Should -Match 'abc123'
        }
    }
}

Describe 'New-ToolkitProjectIndex' {
    InModuleScope O365Toolkit.NotebookLM {
        It 'creates an AST-based project index without comment false positives' {
            $repositoryPath = Join-Path `
                -Path $TestDrive `
                -ChildPath 'IndexRepository'

            $publicPath = Join-Path `
                -Path $repositoryPath `
                -ChildPath 'Public'

            $privatePath = Join-Path `
                -Path $repositoryPath `
                -ChildPath 'Private'

            New-Item `
                -Path $publicPath `
                -ItemType Directory `
                -Force |
                Out-Null

            New-Item `
                -Path $privatePath `
                -ItemType Directory `
                -Force |
                Out-Null

            $publicFile = Join-Path `
                -Path $publicPath `
                -ChildPath 'Get-TestUser.ps1'

            $privateFile = Join-Path `
                -Path $privatePath `
                -ChildPath 'Invoke-TestHelper.ps1'

            Set-Content `
                -LiteralPath $publicFile `
                -Value @'
# This comment says function can be used safely.
function Get-TestUser {
    [CmdletBinding()]
    param()

    return 'User'
}
'@ `
                -Encoding utf8

            Set-Content `
                -LiteralPath $privateFile `
                -Value @'
# This helper should only run internally.
function Invoke-TestHelper {
    [CmdletBinding()]
    param()

    return $true
}
'@ `
                -Encoding utf8

            $inventory = [pscustomobject]@{
                RepositoryPath = $repositoryPath
                IncludedFiles  = @(
                    [pscustomobject]@{
                        Name          = 'Get-TestUser.ps1'
                        FullName      = $publicFile
                        RelativePath  = 'Public\Get-TestUser.ps1'
                        Extension     = '.ps1'
                        Category      = 'PowerShell Script'
                        Length        = 100
                        LastWriteTime = Get-Date
                    }
                    [pscustomobject]@{
                        Name          = 'Invoke-TestHelper.ps1'
                        FullName      = $privateFile
                        RelativePath  = 'Private\Invoke-TestHelper.ps1'
                        Extension     = '.ps1'
                        Category      = 'PowerShell Script'
                        Length        = 100
                        LastWriteTime = Get-Date
                    }
                )
                FileCount       = 2
                CategorySummary = @(
                    [pscustomobject]@{
                        Category = 'PowerShell Script'
                        Count    = 2
                        Bytes    = 200
                    }
                )
            }

            $outputPath = Join-Path `
                -Path $TestDrive `
                -ChildPath 'Project_Index.md'

            $result = New-ToolkitProjectIndex `
                -Inventory $inventory `
                -OutputPath $outputPath

            $result.Success |
                Should -BeTrue

            $result.PublicFunctionCount |
                Should -Be 1

            $result.PrivateFunctionCount |
                Should -Be 1

            $content = Get-Content `
                -LiteralPath $outputPath `
                -Raw

            $content |
                Should -Match 'Get-TestUser'

            $content |
                Should -Match 'Invoke-TestHelper'

            $content |
                Should -Not -Match '^- `can`'

            $content |
                Should -Not -Match '^- `only`'
        }
    }
}

Describe 'New-ToolkitFunctionReference' {
    InModuleScope O365Toolkit.NotebookLM {
        It 'creates structured function documentation from the PowerShell AST' {
            $repositoryPath = Join-Path `
                -Path $TestDrive `
                -ChildPath 'FunctionRepository'

            $publicPath = Join-Path `
                -Path $repositoryPath `
                -ChildPath 'Public'

            New-Item `
                -Path $publicPath `
                -ItemType Directory `
                -Force |
                Out-Null

            $functionFile = Join-Path `
                -Path $publicPath `
                -ChildPath 'Get-TestUser.ps1'

            Set-Content `
                -LiteralPath $functionFile `
                -Value @'
function Get-TestUser {
    <#
    .SYNOPSIS
    Retrieves a test user.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName,

        [Parameter()]
        [switch]$PassThru
    )

    return [pscustomobject]@{
        UserPrincipalName = $UserPrincipalName
    }
}
'@ `
                -Encoding utf8

            $inventory = [pscustomobject]@{
                RepositoryPath = $repositoryPath
                IncludedFiles  = @(
                    [pscustomobject]@{
                        Name          = 'Get-TestUser.ps1'
                        FullName      = $functionFile
                        RelativePath  = 'Public\Get-TestUser.ps1'
                        Extension     = '.ps1'
                        Category      = 'PowerShell Script'
                        Length        = 200
                        LastWriteTime = Get-Date
                    }
                )
                FileCount       = 1
                CategorySummary = @()
            }

            $outputPath = Join-Path `
                -Path $TestDrive `
                -ChildPath 'Function_Reference.md'

            $result = New-ToolkitFunctionReference `
                -Inventory $inventory `
                -OutputPath $outputPath

            $result.Success |
                Should -BeTrue

            $result.FunctionCount |
                Should -Be 1

            $result.PublicFunctionCount |
                Should -Be 1

            $content = Get-Content `
                -LiteralPath $outputPath `
                -Raw

            $content |
                Should -Match '## Get-TestUser'

            $content |
                Should -Match 'Retrieves a test user'

            $content |
                Should -Match '`-UserPrincipalName`'

            $content |
                Should -Match '`-PassThru`'

            $content |
                Should -Match '\[pscustomobject\]'
        }
    }
}

Describe 'New-ToolkitNotebookExport' {
    InModuleScope O365Toolkit.NotebookLM {
        BeforeEach {
            $script:repositoryPath = Join-Path `
                -Path $TestDrive `
                -ChildPath 'Repository'

            $script:outputRoot = Join-Path `
                -Path $TestDrive `
                -ChildPath 'PrivateOutput'

            New-Item `
                -Path $script:repositoryPath `
                -ItemType Directory `
                -Force |
                Out-Null

            Mock Get-ToolkitNotebookMarker {
                [pscustomobject]@{
                    Exists                 = $true
                    BaselineCommit         = 'def456'
                    BaselineTag            = 'core-v0.5.0'
                    Branch                 = 'main'
                    PreviousBaselineCommit = 'old123'
                    NextFeature            = 'Get-ToolkitGroup'
                }
            }

            Mock Get-ToolkitNotebookGitSnapshot {
                [pscustomobject]@{
                    RepositoryPath         = $script:repositoryPath
                    Branch                 = 'main'
                    CurrentCommit          = 'abc123'
                    LatestTag              = 'entra-v0.1.0'
                    PreviousBaselineCommit = 'def456'
                    IncrementalRange       = 'def456..abc123'
                    IsClean                = $true
                    WorkingTreeStatus      = @()
                    CommitLog              = @(
                        'abc123 | 2026-07-31 | Test commit'
                    )
                    DiffStat               = @(
                        '1 file changed'
                    )
                    ChangedFiles           = @(
                        'A Test.ps1'
                    )
                }
            }

            Mock Get-ToolkitNotebookRepositoryInventory {
                [pscustomobject]@{
                    RepositoryPath  = $script:repositoryPath
                    IncludedFiles   = @()
                    FileCount       = 10
                    CategorySummary = @()
                    GeneratedAt     = Get-Date
                }
            }

            Mock New-ToolkitNotebookDocuments {
                param(
                    $Snapshot,
                    $OutputPath,
                    $ExportVersion,
                    $NextFeature,
                    $TestSummary
                )

                New-Item `
                    -Path $OutputPath `
                    -ItemType Directory `
                    -Force |
                    Out-Null

                Set-Content `
                    -LiteralPath (
                        Join-Path `
                            -Path $OutputPath `
                            -ChildPath 'O365Toolkit_Master_Guide.md'
                    ) `
                    -Value '# Test document' `
                    -Encoding utf8

                [pscustomobject]@{
                    Success       = $true
                    OutputPath    = $OutputPath
                    ExportVersion = $ExportVersion
                    CreatedFiles  = @()
                    FileCount     = 5
                    GeneratedAt   = '2026-07-31'
                }
            }

            Mock New-ToolkitProjectIndex {
                param(
                    $Inventory,
                    $OutputPath
                )

                Set-Content `
                    -LiteralPath $OutputPath `
                    -Value '# Project Index' `
                    -Encoding utf8

                [pscustomobject]@{
                    Success              = $true
                    OutputPath           = $OutputPath
                    TotalFiles           = 10
                    FunctionCount        = 5
                    PublicFunctionCount  = 2
                    PrivateFunctionCount = 2
                    TestFileCount        = 1
                    DocumentationCount   = 1
                    RunbookCount         = 0
                    GeneratedAt          = '2026-07-31'
                }
            }

            Mock New-ToolkitFunctionReference {
                param(
                    $Inventory,
                    $OutputPath
                )

                Set-Content `
                    -LiteralPath $OutputPath `
                    -Value '# Function Reference' `
                    -Encoding utf8

                [pscustomobject]@{
                    Success              = $true
                    OutputPath           = $OutputPath
                    FunctionCount        = 5
                    PublicFunctionCount  = 2
                    PrivateFunctionCount = 2
                    GeneratedAt          = '2026-07-31'
                }
            }

            Mock Copy-ToolkitNotebookRepositorySnapshot {
                param(
                    $Inventory,
                    $DestinationPath
                )

                New-Item `
                    -Path $DestinationPath `
                    -ItemType Directory `
                    -Force |
                    Out-Null

                Set-Content `
                    -LiteralPath (
                        Join-Path `
                            -Path $DestinationPath `
                            -ChildPath 'Test.ps1'
                    ) `
                    -Value 'function Test-Export { }' `
                    -Encoding utf8

                [pscustomobject]@{
                    Success         = $true
                    DestinationPath = $DestinationPath
                    FileCount       = 10
                    CopiedFiles     = @()
                    CompletedAt     = Get-Date
                }
            }

            Mock Set-ToolkitNotebookMarker {
                [pscustomobject]@{
                    Success = $true
                }
            }
        }

        It 'creates an expanded ZIP and updates the marker' {
            $result = New-ToolkitNotebookExport `
                -RepositoryPath $script:repositoryPath `
                -OutputRoot $script:outputRoot `
                -ExportVersion 'v0.3' `
                -NextFeature 'Get-ToolkitGroup'

            $result.Success |
                Should -BeTrue

            Test-Path `
                -LiteralPath $result.ZipPath |
                Should -BeTrue

            $result.BaselineCommit |
                Should -Be 'abc123'

            $result.PreviousBaselineCommit |
                Should -Be 'def456'

            $result.DocumentCount |
                Should -Be 7

            $result.InventoryFileCount |
                Should -Be 10

            $result.FunctionCount |
                Should -Be 5

            $result.PublicFunctionCount |
                Should -Be 2

            $result.PrivateFunctionCount |
                Should -Be 2

            $result.TestFileCount |
                Should -Be 1

            $result.DocumentationCount |
                Should -Be 1

            $result.RunbookCount |
                Should -Be 0

            $result.SourceSnapshotIncluded |
                Should -BeFalse

            $result.SourceSnapshotFileCount |
                Should -Be 0

            $result.MarkerUpdated |
                Should -BeTrue

            Test-Path `
                -LiteralPath $result.ProjectIndexPath |
                Should -BeTrue

            Test-Path `
                -LiteralPath $result.FunctionReferencePath |
                Should -BeTrue

            Should -Invoke `
                Get-ToolkitNotebookMarker `
                -Times 1 `
                -Exactly

            Should -Invoke `
                Get-ToolkitNotebookGitSnapshot `
                -Times 1 `
                -Exactly

            Should -Invoke `
                Get-ToolkitNotebookRepositoryInventory `
                -Times 1 `
                -Exactly

            Should -Invoke `
                New-ToolkitNotebookDocuments `
                -Times 1 `
                -Exactly

            Should -Invoke `
                New-ToolkitProjectIndex `
                -Times 1 `
                -Exactly

            Should -Invoke `
                New-ToolkitFunctionReference `
                -Times 1 `
                -Exactly

            Should -Invoke `
                Copy-ToolkitNotebookRepositorySnapshot `
                -Times 0 `
                -Exactly

            Should -Invoke `
                Set-ToolkitNotebookMarker `
                -Times 1 `
                -Exactly
        }

        It 'creates a secure repository snapshot when requested' {
            $result = New-ToolkitNotebookExport `
                -RepositoryPath $script:repositoryPath `
                -OutputRoot $script:outputRoot `
                -ExportVersion 'v0.3' `
                -NextFeature 'Get-ToolkitGroup' `
                -IncludeSourceSnapshot

            $result.Success |
                Should -BeTrue

            $result.SourceSnapshotIncluded |
                Should -BeTrue

            $result.SourceSnapshotFileCount |
                Should -Be 10

            Should -Invoke `
                Copy-ToolkitNotebookRepositorySnapshot `
                -Times 1 `
                -Exactly
        }

        It 'refuses to export from a dirty repository' {
            Mock Get-ToolkitNotebookGitSnapshot {
                [pscustomobject]@{
                    RepositoryPath         = $script:repositoryPath
                    Branch                 = 'feature/test'
                    CurrentCommit          = 'abc123'
                    LatestTag              = 'entra-v0.1.0'
                    PreviousBaselineCommit = 'def456'
                    IncrementalRange       = 'def456..abc123'
                    IsClean                = $false
                    WorkingTreeStatus      = @(
                        '?? Tools/'
                    )
                    CommitLog              = @()
                    DiffStat               = @()
                    ChangedFiles           = @()
                }
            }

            {
                New-ToolkitNotebookExport `
                    -RepositoryPath $script:repositoryPath `
                    -OutputRoot $script:outputRoot `
                    -ExportVersion 'v0.3'
            } |
                Should -Throw `
                    '*repository has uncommitted changes*'

            Should -Invoke `
                Get-ToolkitNotebookRepositoryInventory `
                -Times 0 `
                -Exactly

            Should -Invoke `
                New-ToolkitNotebookDocuments `
                -Times 0 `
                -Exactly

            Should -Invoke `
                New-ToolkitProjectIndex `
                -Times 0 `
                -Exactly

            Should -Invoke `
                New-ToolkitFunctionReference `
                -Times 0 `
                -Exactly

            Should -Invoke `
                Set-ToolkitNotebookMarker `
                -Times 0 `
                -Exactly
        }
    }
}
