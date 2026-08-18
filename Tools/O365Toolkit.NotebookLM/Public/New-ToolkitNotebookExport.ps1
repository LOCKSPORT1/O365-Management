function New-ToolkitNotebookExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ExportVersion = 'v0.4',
        [Parameter(Mandatory = $false)]
        [string]$NextFeature = 'Get-ToolkitGroupMember',
        [Parameter(Mandatory = $false)]
        [switch]$IncludeSourceSnapshot
    )
    process {
        $ErrorActionPreference = 'Stop'
        $repoRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $exportDirName = "NotebookLM_Export_$timestamp"
        $privateExportsDir = Join-Path $repoRoot 'PrivateExports'
        $stagingDir = Join-Path $privateExportsDir $exportDirName
        if (-not (Test-Path $privateExportsDir)) {
            New-Item -Path $privateExportsDir -ItemType Directory -Force | Out-Null
        }
        if (Test-Path $stagingDir) {
            Remove-Item -Path $stagingDir -Recurse -Force
        }
        New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null
        Write-Host "Running pre-export Pester quality gate..." -ForegroundColor Cyan
        $testResult = Invoke-Pester -Path "$repoRoot\Modules\O365Toolkit.Entra\Tests" -PassThru
        $testSummaryContent = @"
# Quality Gate Execution Summary
Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Total Tests: $($testResult.TotalCount)
Passed: $($testResult.PassedCount)
Failed: $($testResult.FailedCount)
Result: $(if ($testResult.FailedCount -eq 0) { 'PASS' } else { 'FAIL' })
"@
        Set-Content -Path (Join-Path $stagingDir 'Test_Summary.md') -Value $testSummaryContent
        if ($testResult.FailedCount -gt 0) {
            throw "Export blocked: Pester quality gate reported $($testResult.FailedCount) test failure(s)."
        }
        # Generate Function Reference, Project Index, and Module Books using -Path
        New-ToolkitFunctionReference -Path $repoRoot -OutputPath (Join-Path $stagingDir "Function_Reference.md")
        New-ToolkitProjectIndex -Path $repoRoot -OutputPath (Join-Path $stagingDir "Project_Index.md")
        Write-Host "Generating Module Source Books..." -ForegroundColor Cyan
        $moduleBooksPath = Join-Path $stagingDir "ModuleBooks"
        New-ToolkitModuleBooks -Path $repoRoot -OutputDirectory $moduleBooksPath
        # Include Source Snapshot if requested
        if ($IncludeSourceSnapshot) {
            $snapshotDir = Join-Path $stagingDir 'RepositorySnapshot'
            New-Item -Path $snapshotDir -ItemType Directory -Force | Out-Null
            Copy-Item -Path "$repoRoot\Core" -Destination $snapshotDir -Recurse -Force
            Copy-Item -Path "$repoRoot\Modules" -Destination $snapshotDir -Recurse -Force
            Copy-Item -Path "$repoRoot\Tools" -Destination $snapshotDir -Recurse -Force
        }
        # Compress into a secure private zip package
        $zipPath = "$stagingDir.zip"
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Compress-Archive -Path "$stagingDir\*" -DestinationPath $zipPath -CompressionLevel Optimal
        Write-Host "PASS: Successfully created NotebookLM export package: $zipPath" -ForegroundColor Green
        return [pscustomobject]@{
            Success            = $true
            ZipPath            = $zipPath
            ExportDirectory    = $stagingDir
            InventoryFileCount = (Get-ChildItem -Path $stagingDir -Recurse -File).Count
            TestSummary        = $testResult
        }
    }
}
