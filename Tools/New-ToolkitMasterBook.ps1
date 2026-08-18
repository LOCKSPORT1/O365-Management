# Tools/New-ToolkitMasterBook.ps1
# Track  : NEUTRAL
# Purpose: Consolidate every artifact from a NotebookLM export staging folder
#          into ONE stable master Markdown file that is overwritten on each run.
#          Gives a single source to re-upload rather than a growing pile of
#          timestamped bundles.
# CHANGE : 2026-08-18 - Initial version. Fence-aware heading demotion, R3.9
#          compliant collection handling, SupportsShouldProcess per R2.8.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Export staging folder. Default: newest NotebookLM_Export_* under PrivateExports.
    [Parameter(Position = 0)]
    [string] $StagingPath,

    # Master file path. Default: PrivateExports\O365Toolkit_MasterBook.md
    [Parameter()]
    [string] $OutputPath,

    [Parameter()]
    [string] $RepositoryPath,

    # Keep the previous master as .prev.md before overwriting.
    [Parameter()]
    [switch] $Backup
)

# --- repo root ------------------------------------------------------------
if (-not $RepositoryPath) {
    $current = $PSScriptRoot
    if (-not $current) { $current = (Get-Location).Path }

    $found = $null
    while ($current) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) { $found = $current; break }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }

    $RepositoryPath = (Get-Location).Path
    if ($found) { $RepositoryPath = $found }
}
$RepositoryPath = $RepositoryPath.TrimEnd('\', '/')

$exportRoot = Join-Path -Path $RepositoryPath -ChildPath 'PrivateExports'

# --- locate the staging folder -------------------------------------------
if (-not $StagingPath) {
    if (-not (Test-Path -LiteralPath $exportRoot)) {
        throw "New-ToolkitMasterBook: export root not found at '$exportRoot'. Run New-ToolkitNotebookExport first."
    }

    $candidates = @(Get-ChildItem -LiteralPath $exportRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'NotebookLM_Export_*' } |
        Sort-Object -Property Name -Descending)

    if ($candidates.Count -eq 0) {
        throw "New-ToolkitMasterBook: no NotebookLM_Export_* folder under '$exportRoot'. Run New-ToolkitNotebookExport first."
    }
    $StagingPath = $candidates[0].FullName
}

if (-not (Test-Path -LiteralPath $StagingPath)) {
    throw "New-ToolkitMasterBook: staging path not found: $StagingPath"
}

if (-not $OutputPath) {
    $OutputPath = Join-Path -Path $exportRoot -ChildPath 'O365Toolkit_MasterBook.md'
}

# --- ordering: narrative first, then reference, then module books ---------
# Anything not matched by these prefixes is appended alphabetically at the end,
# so a new artifact is never silently dropped.
$leadOrder = @(
    'README'
    'Project_Index'
    'Function_Reference'
)

$allFiles = @(Get-ChildItem -LiteralPath $StagingPath -Filter '*.md' -Recurse -ErrorAction SilentlyContinue)
if ($allFiles.Count -eq 0) {
    throw "New-ToolkitMasterBook: no .md files found under '$StagingPath'."
}

$ordered = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

foreach ($prefix in $leadOrder) {
    $match = @($allFiles | Where-Object { $_.BaseName -eq $prefix } | Sort-Object Name)
    foreach ($m in $match) { $ordered.Add($m) }
}

# Module books: numeric prefix (05_, 06_, ...) sorts naturally by name.
$books = @($allFiles |
    Where-Object { $_.Name -match '^\d{2}_' } |
    Sort-Object -Property Name)
foreach ($b in $books) { $ordered.Add($b) }

# Anything left over.
$remaining = @($allFiles |
    Where-Object { $ordered -notcontains $_ } |
    Sort-Object -Property FullName)
foreach ($r in $remaining) { $ordered.Add($r) }

# --- fence-aware heading demotion ----------------------------------------
function Convert-ToolkitDemotedMarkdown {
    <#
    .SYNOPSIS
        Demotes markdown headings by one level without touching fenced code.
    .DESCRIPTION
        Module books embed PowerShell inside ``` fences, and those blocks are
        full of '#' comment lines. A naive regex would convert them into
        headings. This tracks fence state and only demotes headings outside
        fenced regions.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter()]
        [int] $Levels = 1
    )

    $lines  = @($Text -split "`r?`n")
    $output = [System.Collections.Generic.List[string]]::new()
    $inFence = $false
    $pad = '#' * $Levels

    foreach ($line in $lines) {

        # A fence marker is ``` or ~~~ at the start of a line (allowing indent).
        if ($line -match '^\s*(```|~~~)') {
            $inFence = -not $inFence
            $output.Add($line)
            continue
        }

        if (-not $inFence -and $line -match '^(#{1,5})\s') {
            $output.Add($pad + $line)
        }
        else {
            $output.Add($line)
        }
    }

    return ($output -join "`r`n")
}

# --- git context ----------------------------------------------------------
$gitBranch = 'unknown'
$gitCommit = 'unknown'
Push-Location -LiteralPath $RepositoryPath
try {
    $b = (& git rev-parse --abbrev-ref HEAD 2>$null)
    $c = (& git rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -eq 0) {
        if ($b) { $gitBranch = ([string]$b).Trim() }
        if ($c) { $gitCommit = ([string]$c).Trim() }
    }
}
catch { }
finally { Pop-Location }

# --- assemble -------------------------------------------------------------
$generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$stagingName = Split-Path -Path $StagingPath -Leaf

$sb = [System.Text.StringBuilder]::new()

$null = $sb.AppendLine('# O365Toolkit Master Source Book')
$null = $sb.AppendLine()
$null = $sb.AppendLine('Consolidated export of every module source book, the function reference, and the project index for the O365-Management PowerShell toolkit. This is a tenant-neutral automation library targeting the Microsoft Graph API.')
$null = $sb.AppendLine()
$null = $sb.AppendLine("**Generated:** $generated  ")
$null = $sb.AppendLine("**Source export:** $stagingName  ")
$null = $sb.AppendLine("**Git branch:** $gitBranch  ")
$null = $sb.AppendLine("**Git commit:** $gitCommit  ")
$null = $sb.AppendLine("**Sections:** $($ordered.Count)")
$null = $sb.AppendLine()
$null = $sb.AppendLine('---')
$null = $sb.AppendLine()
$null = $sb.AppendLine('## Contents')
$null = $sb.AppendLine()

$sectionIndex = 0
foreach ($file in $ordered) {
    $sectionIndex++
    $null = $sb.AppendLine("$sectionIndex. $($file.BaseName)")
}
$null = $sb.AppendLine()

$sectionIndex = 0
$manifest = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($file in $ordered) {

    $sectionIndex++

    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) {
        Write-Warning "Empty, skipped: $($file.Name)"
        continue
    }

    $demoted = Convert-ToolkitDemotedMarkdown -Text $content.TrimEnd() -Levels 1

    $null = $sb.AppendLine()
    $null = $sb.AppendLine('---')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("# Section $sectionIndex - $($file.BaseName)")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("*Source file: ``$($file.Name)``*")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine($demoted)
    $null = $sb.AppendLine()

    $manifest.Add([pscustomobject]@{
        Section = $sectionIndex
        Name    = $file.BaseName
        KB      = [math]::Round($file.Length / 1KB, 1)
    })
}

$masterText = $sb.ToString()

# --- write ----------------------------------------------------------------
$outDir = Split-Path -Path $OutputPath -Parent
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    $null = New-Item -ItemType Directory -Path $outDir -Force
}

if ($PSCmdlet.ShouldProcess($OutputPath, 'Write consolidated master book')) {

    if ($Backup -and (Test-Path -LiteralPath $OutputPath)) {
        $prev = [System.IO.Path]::ChangeExtension($OutputPath, $null) + '.prev.md'
        Copy-Item -LiteralPath $OutputPath -Destination $prev -Force
    }

    Set-Content -LiteralPath $OutputPath -Value $masterText -Encoding utf8
}

$masterKB = 0
if (Test-Path -LiteralPath $OutputPath) {
    $masterKB = [math]::Round((Get-Item -LiteralPath $OutputPath).Length / 1KB, 1)
}

Write-Host ''
if ($WhatIfPreference) {
    Write-Host "WhatIf: master book NOT written: $OutputPath" -ForegroundColor Yellow
} else {
    Write-Host "Master book written: $OutputPath" -ForegroundColor Green
}
Write-Host "  $($manifest.Count) section(s), $masterKB KB" -ForegroundColor DarkGray
Write-Host ''
$manifest | Format-Table -AutoSize

return [pscustomobject]@{
    MasterPath  = $OutputPath
    StagingPath = $StagingPath
    Sections    = $manifest.Count
    SizeKB      = $masterKB
    Generated   = $generated
    GitCommit   = $gitCommit
}
