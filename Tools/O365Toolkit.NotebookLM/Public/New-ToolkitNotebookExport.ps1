function New-ToolkitNotebookExport {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath = (Get-Location).Path,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OutputRoot = (
            Join-Path `
                $env:USERPROFILE `
                'Documents\Private-O365Toolkit-NotebookLM'
        ),

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ExportVersion,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$NextFeature,

        [Parameter()]
        [switch]$IncludeSourceSnapshot,

        [Parameter()]
        [switch]$RunTests
    )

    $resolvedRepositoryPath = (
        Resolve-Path `
            -LiteralPath $RepositoryPath `
            -ErrorAction Stop
    ).Path

    if (-not (Test-Path -LiteralPath $OutputRoot)) {
        New-Item `
            -Path $OutputRoot `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop |
            Out-Null
    }

    $markerPath = Join-Path `
        -Path $OutputRoot `
        -ChildPath 'SESSION_MARKER_PRIVATE.md'

    $marker = Get-ToolkitNotebookMarker `
        -MarkerPath $markerPath

    $snapshot = Get-ToolkitNotebookGitSnapshot `
        -RepositoryPath $resolvedRepositoryPath `
        -PreviousBaselineCommit $marker.BaselineCommit

    if (-not $snapshot.IsClean) {
        throw (
            'The repository has uncommitted changes. ' +
            'Commit or stash them before creating a final export.' +
            [environment]::NewLine +
            ($snapshot.WorkingTreeStatus -join [environment]::NewLine)
        )
    }

    $inventory = Get-ToolkitNotebookRepositoryInventory `
        -RepositoryPath $resolvedRepositoryPath

    $timestamp = Get-Date `
        -Format 'yyyyMMdd-HHmmss'

    $exportName = (
        'O365Toolkit_NotebookLM_Private_{0}_{1}' -f
        $ExportVersion,
        $timestamp
    )

    $workingPath = Join-Path `
        -Path $OutputRoot `
        -ChildPath $exportName

    $documentPath = Join-Path `
        -Path $workingPath `
        -ChildPath 'NotebookLM'

    New-Item `
        -Path $documentPath `
        -ItemType Directory `
        -Force `
        -ErrorAction Stop |
        Out-Null

    $testSummary = 'Tests were not run during this export.'

    if ($RunTests) {
        $testPaths = @()

        $coreTests = Join-Path `
            -Path $resolvedRepositoryPath `
            -ChildPath 'Core\Tests'

        if (Test-Path -LiteralPath $coreTests) {
            $testPaths += $coreTests
        }

        $modulesPath = Join-Path `
            -Path $resolvedRepositoryPath `
            -ChildPath 'Modules'

        if (Test-Path -LiteralPath $modulesPath) {
            $moduleTestFolders = Get-ChildItem `
                -LiteralPath $modulesPath `
                -Recurse `
                -Directory `
                -Filter 'Tests' `
                -ErrorAction SilentlyContinue

            foreach ($folder in $moduleTestFolders) {
                $testPaths += $folder.FullName
            }
        }

        $notebookTests = Join-Path `
            -Path $resolvedRepositoryPath `
            -ChildPath 'Tools\O365Toolkit.NotebookLM\Tests'

        if (Test-Path -LiteralPath $notebookTests) {
            $testPaths += $notebookTests
        }

        $testPaths = @(
            $testPaths |
            Select-Object -Unique
        )

        if ($testPaths.Count -gt 0) {
            $testResult = Invoke-Pester `
                -Path $testPaths `
                -Output None `
                -PassThru

            $testSummary = @"
Total: $($testResult.TotalCount)
Passed: $($testResult.PassedCount)
Failed: $($testResult.FailedCount)
Skipped: $($testResult.SkippedCount)
Duration: $($testResult.Duration)
"@

            if ($testResult.FailedCount -gt 0) {
                throw (
                    "Pester reported $($testResult.FailedCount) failing tests."
                )
            }
        }
    }

    $documentResult = New-ToolkitNotebookDocuments `
        -Snapshot $snapshot `
        -OutputPath $documentPath `
        -ExportVersion $ExportVersion `
        -NextFeature $NextFeature `
        -TestSummary $testSummary

    $projectIndexPath = Join-Path `
        -Path $documentPath `
        -ChildPath 'Project_Index.md'

    $projectIndexResult = New-ToolkitProjectIndex `
        -Inventory $inventory `
        -OutputPath $projectIndexPath

    $functionReferencePath = Join-Path `
        -Path $documentPath `
        -ChildPath 'Function_Reference.md'

    $functionReferenceResult = New-ToolkitFunctionReference `
        -Inventory $inventory `
        -OutputPath $functionReferencePath

    $sourceSnapshotResult = $null

    if ($IncludeSourceSnapshot) {
        $sourceSnapshotPath = Join-Path `
            -Path $workingPath `
            -ChildPath 'RepositorySnapshot'

        $sourceSnapshotResult = Copy-ToolkitNotebookRepositorySnapshot `
            -Inventory $inventory `
            -DestinationPath $sourceSnapshotPath
    }

    $zipPath = Join-Path `
        -Path $OutputRoot `
        -ChildPath "$exportName.zip"

    Compress-Archive `
        -Path (Join-Path $workingPath '*') `
        -DestinationPath $zipPath `
        -CompressionLevel Optimal `
        -Force

    $markerWriteResult = Set-ToolkitNotebookMarker `
        -MarkerPath $markerPath `
        -ExportVersion $ExportVersion `
        -BaselineCommit $snapshot.CurrentCommit `
        -BaselineTag $snapshot.LatestTag `
        -Branch $snapshot.Branch `
        -PreviousBaselineCommit $marker.BaselineCommit `
        -NextFeature $NextFeature

    $sourceSnapshotFileCount = if (
        $null -ne $sourceSnapshotResult
    ) {
        $sourceSnapshotResult.FileCount
    }
    else {
        0
    }

    return [pscustomobject]@{
        Success                 = $true
        ExportVersion           = $ExportVersion
        RepositoryPath          = $resolvedRepositoryPath
        OutputRoot              = $OutputRoot
        WorkingPath             = $workingPath
        ZipPath                 = $zipPath
        MarkerPath              = $markerPath
        BaselineCommit          = $snapshot.CurrentCommit
        PreviousBaselineCommit  = $marker.BaselineCommit
        IncrementalRange        = $snapshot.IncrementalRange
        DocumentCount           = $documentResult.FileCount + 2
        ProjectIndexPath        = $projectIndexResult.OutputPath
        FunctionReferencePath   = $functionReferenceResult.OutputPath
        InventoryFileCount      = $inventory.FileCount
        FunctionCount           = $functionReferenceResult.FunctionCount
        PublicFunctionCount     = $functionReferenceResult.PublicFunctionCount
        PrivateFunctionCount    = $functionReferenceResult.PrivateFunctionCount
        TestFileCount           = $projectIndexResult.TestFileCount
        DocumentationCount      = $projectIndexResult.DocumentationCount
        RunbookCount            = $projectIndexResult.RunbookCount
        SourceSnapshotIncluded  = [bool]$IncludeSourceSnapshot
        SourceSnapshotFileCount = $sourceSnapshotFileCount
        TestsRun                = [bool]$RunTests
        MarkerUpdated           = $markerWriteResult.Success
    }
}