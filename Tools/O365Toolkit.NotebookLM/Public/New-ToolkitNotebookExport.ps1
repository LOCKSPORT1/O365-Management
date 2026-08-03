function New-ToolkitNotebookExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [Alias('RepositoryRoot', 'Repository')]
        [string]$RepositoryPath = (Get-Location).Path,

        [Parameter(Mandatory = $false)]
        [Alias('OutputDirectory', 'OutputPath')]
        [string]$OutputRoot,

        [Parameter(Mandatory = $false)]
        [string]$ExportVersion = 'v0.2',

        [Parameter(Mandatory = $false)]
        [string]$NextFeature = 'Get-ToolkitGroup',

        [Parameter(Mandatory = $false)]
        [Alias('IncludeSnapshot')]
        [switch]$IncludeSourceSnapshot
    )

    process {
        $ErrorActionPreference = 'Stop'

        # Get git snapshot and verify repo is clean
        $gitSnapshot = Get-ToolkitNotebookGitSnapshot -RepositoryPath $RepositoryPath
        if (-not $gitSnapshot.IsClean) {
            throw "Repository at '$RepositoryPath' has uncommitted changes. Commit or stash before running export."
        }

        # Resolve output directory
        if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
            $OutputRoot = Join-Path -Path $RepositoryPath -ChildPath 'PrivateExports'
        }

        if (-not (Test-Path -LiteralPath $OutputRoot)) {
            $null = New-Item -Path $OutputRoot -ItemType Directory -Force
        }

        # Setup staging directory
        $stagingDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.Guid]::NewGuid().ToString())
        $null = New-Item -Path $stagingDirectory -ItemType Directory -Force

        try {
            $notebookLmDir = Join-Path -Path $stagingDirectory -ChildPath 'NotebookLM'
            $null = New-Item -Path $notebookLmDir -ItemType Directory -Force

            # Collect repository inventory
            $inventory = Get-ToolkitNotebookRepositoryInventory -RepositoryPath $RepositoryPath

            # Generate top-level NotebookLM documents
            $docResult = New-ToolkitNotebookDocuments `
                -Snapshot $gitSnapshot `
                -OutputPath $notebookLmDir `
                -ExportVersion $ExportVersion `
                -NextFeature $NextFeature

            # Generate Project Index & Function Reference
            $projectIndexPath = Join-Path -Path $notebookLmDir -ChildPath 'Project_Index.md'
            $indexResult = New-ToolkitProjectIndex -Inventory $inventory -OutputPath $projectIndexPath

            $functionRefPath = Join-Path -Path $notebookLmDir -ChildPath 'Function_Reference.md'
            $funcRefResult = New-ToolkitFunctionReference -Inventory $inventory -OutputPath $functionRefPath

            # Generate ModuleBooks sub-structure
            $moduleBooksDir = Join-Path -Path $notebookLmDir -ChildPath 'ModuleBooks'
            $moduleBooksResult = New-ToolkitModuleBooks -Inventory $inventory -OutputPath $moduleBooksDir

            # Handle source snapshot if requested
            $snapshotIncluded = $false
            $snapshotFileCount = 0
            if ($IncludeSourceSnapshot) {
                $snapshotDir = Join-Path -Path $stagingDirectory -ChildPath 'RepositorySnapshot'
                $snapshotResult = Copy-ToolkitNotebookRepositorySnapshot -Inventory $inventory -DestinationPath $snapshotDir
                $snapshotIncluded = [bool]$snapshotResult.Success
                $snapshotFileCount = [int]$snapshotResult.FileCount
            }

            # Generate ZIP file
            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $zipFileName = "NotebookLM_Export_$timestamp.zip"
            $zipPath = Join-Path -Path $OutputRoot -ChildPath $zipFileName

            if (Test-Path -LiteralPath $zipPath) {
                Remove-Item -LiteralPath $zipPath -Force
            }

            Compress-Archive -Path "$stagingDirectory\*" -DestinationPath $zipPath -CompressionLevel Optimal

            # Write/Update private session marker
            $markerPath = Join-Path -Path $RepositoryPath -ChildPath 'SESSION_MARKER_PRIVATE.md'
            $markerResult = Set-ToolkitNotebookMarker `
                -MarkerPath $markerPath `
                -ExportVersion $ExportVersion `
                -BaselineCommit $gitSnapshot.CurrentCommit `
                -BaselineTag $gitSnapshot.LatestTag `
                -Branch $gitSnapshot.Branch `
                -PreviousBaselineCommit $gitSnapshot.PreviousBaselineCommit `
                -NextFeature $NextFeature

            return [pscustomobject]@{
                Success                  = $true
                ZipPath                  = $zipPath
                BaselineCommit           = $gitSnapshot.CurrentCommit
                PreviousBaselineCommit   = $gitSnapshot.PreviousBaselineCommit
                DocumentCount            = ($docResult.FileCount + 2)
                InventoryFileCount       = $inventory.FileCount
                FunctionCount            = $indexResult.FunctionCount
                PublicFunctionCount      = $indexResult.PublicFunctionCount
                PrivateFunctionCount     = $indexResult.PrivateFunctionCount
                TestFileCount            = $indexResult.TestFileCount
                DocumentationCount       = $indexResult.DocumentationCount
                RunbookCount             = $indexResult.RunbookCount
                SourceSnapshotIncluded   = $snapshotIncluded
                SourceSnapshotFileCount = $snapshotFileCount
                MarkerUpdated            = [bool]$markerResult.Success
                ProjectIndexPath         = $projectIndexPath
                FunctionReferencePath    = $functionRefPath
                ModuleBooksPath          = $moduleBooksDir
            }
        }
        finally {
            if (Test-Path -LiteralPath $stagingDirectory) {
                Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}