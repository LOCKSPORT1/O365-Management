$modulePath = Join-Path `
    $PSScriptRoot `
    '..\O365Toolkit.NotebookLM.psd1'

Import-Module `
    $modulePath `
    -Force `
    -ErrorAction Stop

Describe 'O365Toolkit.NotebookLM module' {
    It 'has a valid module manifest' {
        $manifestPath = Join-Path `
            $PSScriptRoot `
            '..\O365Toolkit.NotebookLM.psd1'

        Test-ModuleManifest `
            -Path $manifestPath `
            -ErrorAction Stop |
            Should -Not -BeNullOrEmpty
    }

    It 'exports New-ToolkitNotebookExport' {
        Get-Command `
            New-ToolkitNotebookExport `
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
            'New-ToolkitNotebookDocuments'
        )

        foreach ($helperName in $helperNames) {
            Get-Command `
                $helperName `
                -ErrorAction SilentlyContinue |
                Should -BeNullOrEmpty
        }
    }
}

Describe 'NotebookLM private marker helpers' {
    InModuleScope O365Toolkit.NotebookLM {
        BeforeEach {
            $script:testRoot = Join-Path `
                $TestDrive `
                'PrivateNotebookLM'

            $script:markerPath = Join-Path `
                $script:testRoot `
                'SESSION_MARKER_PRIVATE.md'
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

            Test-Path $script:markerPath |
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

Describe 'New-ToolkitNotebookDocuments' {
    InModuleScope O365Toolkit.NotebookLM {
        It 'creates the expected NotebookLM source files' {
            $outputPath = Join-Path `
                $TestDrive `
                'Documents'

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
Total: 61
Passed: 61
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
                Test-Path (
                    Join-Path $outputPath $fileName
                ) |
                    Should -BeTrue
            }

            $masterGuide = Get-Content `
                -LiteralPath (
                    Join-Path `
                        $outputPath `
                        'O365Toolkit_Master_Guide.md'
                ) `
                -Raw

            $masterGuide |
                Should -Match 'Get-ToolkitGroup'

            $masterGuide |
                Should -Match 'abc123'
        }
    }
}

Describe 'New-ToolkitNotebookExport' {
    InModuleScope O365Toolkit.NotebookLM {
        BeforeEach {
            $script:repositoryPath = Join-Path `
                $TestDrive `
                'Repository'

            $script:outputRoot = Join-Path `
                $TestDrive `
                'PrivateOutput'

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
                            $OutputPath `
                            'O365Toolkit_Master_Guide.md'
                    ) `
                    -Value '# Test document' `
                    -Encoding utf8

                [pscustomobject]@{
                    Success       = $true
                    OutputPath    = $OutputPath
                    ExportVersion = $ExportVersion
                    CreatedFiles  = @()
                    FileCount     = 1
                    GeneratedAt   = '2026-07-31'
                }
            }

            Mock Set-ToolkitNotebookMarker {
                [pscustomobject]@{
                    Success = $true
                }
            }
        }

        It 'creates a ZIP and updates the marker' {
            $result = New-ToolkitNotebookExport `
                -RepositoryPath $script:repositoryPath `
                -OutputRoot $script:outputRoot `
                -ExportVersion 'v0.2' `
                -NextFeature 'Get-ToolkitGroup'

            $result.Success |
                Should -BeTrue

            Test-Path $result.ZipPath |
                Should -BeTrue

            $result.BaselineCommit |
                Should -Be 'abc123'

            $result.PreviousBaselineCommit |
                Should -Be 'def456'

            $result.DocumentCount |
                Should -Be 1

            $result.MarkerUpdated |
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
                New-ToolkitNotebookDocuments `
                -Times 1 `
                -Exactly

            Should -Invoke `
                Set-ToolkitNotebookMarker `
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
                    -ExportVersion 'v0.2'
            } |
                Should -Throw `
                    '*repository has uncommitted changes*'

            Should -Invoke `
                New-ToolkitNotebookDocuments `
                -Times 0 `
                -Exactly

            Should -Invoke `
                Set-ToolkitNotebookMarker `
                -Times 0 `
                -Exactly
        }
    }
}