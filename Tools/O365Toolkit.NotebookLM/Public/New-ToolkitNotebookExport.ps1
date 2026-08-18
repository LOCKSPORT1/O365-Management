function New-ToolkitNotebookExport {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string]$ExportPath,

        [Parameter()]
        [string]$RepositoryPath,

        [Parameter()]
        [switch]$SkipQualityGate,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Config = @{ Environment = 'Global' }
    )

    $ErrorActionPreference = 'Stop'

    if (-not $Config) { $Config = @{ Environment = 'Global' } }

    if (-not $RepositoryPath) {
        $current = $PSScriptRoot
        if (-not $current) { $current = (Get-Location).Path }

        while ($current -and -not (Test-Path -Path (Join-Path -Path $current -ChildPath '.git'))) {
            $parent = [System.IO.Path]::GetDirectoryName($current)
            if ($parent -eq $current) { break }
            $current = $parent
        }

        if ($current -and (Test-Path -Path (Join-Path -Path $current -ChildPath '.git'))) {
            $RepositoryPath = $current
        } else {
            $RepositoryPath = (Get-Location).Path
        }
    }

    if (-not (Test-Path -Path (Join-Path -Path $RepositoryPath -ChildPath '.git'))) {
        throw "Repository root not found at '$RepositoryPath'."
    }

    if (-not $SkipQualityGate) {
        Write-Host "Running pre-export Pester quality gate..." -ForegroundColor Yellow
        Import-Module -Name Pester -MinimumVersion 5.0.0 -Force -ErrorAction Stop

        $coreManifest = Join-Path -Path $RepositoryPath -ChildPath 'Core\O365Toolkit.Core.psd1'
        if (Test-Path -Path $coreManifest) {
            Import-Module -Name $coreManifest -Force -ErrorAction SilentlyContinue
        }

        $testPaths = @(
            (Join-Path -Path $RepositoryPath -ChildPath 'Modules\O365Toolkit.Entra\Tests')
            (Join-Path -Path $RepositoryPath -ChildPath 'Modules\O365Toolkit.Teams\Tests')
            (Join-Path -Path $RepositoryPath -ChildPath 'Modules\O365Toolkit.Security\Tests')
            (Join-Path -Path $RepositoryPath -ChildPath 'Modules\O365Toolkit.SharePoint\Tests')
        ) | Where-Object { Test-Path $_ }

        $pesterConfig = [PesterConfiguration]::Default
        $pesterConfig.Run.Path = $testPaths
        $pesterConfig.Run.PassThru = $true
        $pesterConfig.Output.Verbosity = 'Minimal'

        $pesterResult = Invoke-Pester -Configuration $pesterConfig
        if ($pesterResult.FailedCount -gt 0) {
            throw "Export aborted: $($pesterResult.FailedCount) test(s) failed."
        }

        # R3.9 gate: statement-expression assignments that collapse to $null.
        $r39Scanner = Join-Path -Path $RepositoryPath -ChildPath 'Tools\Find-ToolkitStatementAssignment.ps1'
        if (Test-Path -LiteralPath $r39Scanner) {
            Write-Host 'Running R3.9 statement-assignment gate...' -ForegroundColor Yellow
            $r39 = @(& $r39Scanner -RepositoryPath $RepositoryPath -MinimumRisk HIGH -PassThru)
            if ($r39.Count -gt 0) {
                $detail = ($r39 | ForEach-Object { "$($_.File):$($_.Line) $($_.Variable)" }) -join "`n  "
                throw "Export aborted: $($r39.Count) R3.9 violation(s).`n  $detail`nRun Tools\Repair-ToolkitStatementAssignment.ps1 -WhatIf"
            }
        }
        else {
            Write-Warning "R3.9 scanner not found at $r39Scanner - gate skipped."
        }
    }

    $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $exportBaseDir = if ($ExportPath) { $ExportPath } else { Join-Path -Path $RepositoryPath -ChildPath 'PrivateExports' }
    $exportStagingDir = Join-Path -Path $exportBaseDir -ChildPath "NotebookLM_Export_$timestamp"
    $moduleBooksDir = Join-Path -Path $exportStagingDir -ChildPath 'ModuleBooks'

    $null = New-Item -ItemType Directory -Path $moduleBooksDir -Force

    Write-Host "[*] Compiling Module Source Books..." -ForegroundColor Yellow
$rawBooks = New-ToolkitModuleBooks -DestinationPath $moduleBooksDir -RepositoryPath $RepositoryPath -Config $Config
$books = @()
if ($rawBooks) { $books = @($rawBooks) }

    Write-Host "[*] Extracting Function Reference..." -ForegroundColor Yellow
    $fnRefPath = Join-Path -Path $exportStagingDir -ChildPath 'Function_Reference.md'
    $null = New-ToolkitFunctionReference -DestinationPath $fnRefPath -RepositoryPath $RepositoryPath -Config $Config

    Write-Host "[*] Generating Project Index..." -ForegroundColor Yellow
    $projIndexPath = Join-Path -Path $exportStagingDir -ChildPath 'Project_Index.md'
    $null = New-ToolkitProjectIndex -DestinationPath $projIndexPath -RepositoryPath $RepositoryPath -Config $Config

    Write-Host "[*] Copying core root architecture documents..." -ForegroundColor Yellow
    $null = New-ToolkitNotebookDocuments -DestinationPath $exportStagingDir -RepositoryPath $RepositoryPath -Config $Config

    $zipPath = "$exportStagingDir.zip"
    Write-Host "[*] Packaging archive: $zipPath..." -ForegroundColor Yellow
    if (Test-Path -Path $zipPath) { Remove-Item -Path $zipPath -Force }
    Compress-Archive -Path "$exportStagingDir\*" -DestinationPath $zipPath -Force

    $allExportedFiles = Get-ChildItem -Path $exportStagingDir -Recurse -File

    Write-Host "`nPASS: Knowledge export bundle generated successfully!" -ForegroundColor Green

    $bookFilesList = @()
    if ($books.Count -gt 0) { $bookFilesList = @($books | ForEach-Object { $_.BookFile }) }

    return [PSCustomObject]@{
        ExportVersion = 'v0.4'
        Timestamp     = $timestamp
        PackagePath   = $zipPath
        StagingPath   = $exportStagingDir
        TotalFiles    = $allExportedFiles.Count
        ModuleBooks   = $bookFilesList
        Status        = 'Success'
    }
}
