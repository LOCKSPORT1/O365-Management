# Tools/Publish-ToolkitMasterBook.ps1
# Track  : NEUTRAL
# Purpose: Prepare the master book for upload to NotebookLM. Optionally
#          regenerates it, verifies integrity, opens the containing folder with
#          the file selected, opens the notebook in a browser, and can stage the
#          contents on the clipboard for the "Copied text" source type.
#          NOTE: NotebookLM exposes no public API for source management, so the
#          upload itself is manual. This removes every step except the clicks.
# CHANGE : 2026-08-18 - Initial version.

[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepositoryPath,

    # Run New-ToolkitNotebookExport first so the book reflects current code.
    [Parameter()]
    [switch] $Regenerate,

    # Copy the file contents to the clipboard for Add source > Copied text.
    [Parameter()]
    [switch] $ToClipboard,

    # Your notebook URL. Opens in the default browser when supplied.
    [Parameter()]
    [string] $NotebookUrl,

    # Skip opening Explorer.
    [Parameter()]
    [switch] $NoExplorer
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

$masterPath = Join-Path $RepositoryPath 'PrivateExports\O365Toolkit_MasterBook.md'

# --- optionally regenerate -------------------------------------------------
if ($Regenerate) {
    Write-Host 'Regenerating export and master book...' -ForegroundColor Yellow
    try {
        Import-Module (Join-Path $RepositoryPath 'Core\O365Toolkit.Core.psd1') -Force -ErrorAction Stop
        Import-Module (Join-Path $RepositoryPath 'Tools\O365Toolkit.NotebookLM\O365Toolkit.NotebookLM.psd1') -Force -ErrorAction Stop
        $null = New-ToolkitNotebookExport
    }
    catch {
        Write-Warning "Export failed: $($_.Exception.Message)"
        Write-Warning 'Using the existing master book if present.'
    }
}

if (-not (Test-Path -LiteralPath $masterPath)) {
    throw "Master book not found at '$masterPath'. Run New-ToolkitNotebookExport, or re-run with -Regenerate."
}

# --- verify ----------------------------------------------------------------
$item = Get-Item -LiteralPath $masterPath
$text = Get-Content -LiteralPath $masterPath -Raw

$sizeKB   = [math]::Round($item.Length / 1KB, 1)
$sections = @([regex]::Matches($text, '(?m)^# Section \d+')).Count
$fences   = @([regex]::Matches($text, '(?m)^\s*```')).Count

$commit = 'unknown'
$m = [regex]::Match($text, '\*\*Git commit:\*\*\s*(\S+)')
if ($m.Success) { $commit = $m.Groups[1].Value }

$generated = 'unknown'
$m2 = [regex]::Match($text, '\*\*Generated:\*\*\s*([^\r\n]+)')
if ($m2.Success) { $generated = $m2.Groups[1].Value.Trim() }

# Fenced code must be balanced, and no PowerShell comment should have been
# promoted into a heading by the demotion pass.
$damaged = @($text -split "`n" | Select-String '^#{2,}\s*\$').Count

Write-Host ''
Write-Host 'Master book ready' -ForegroundColor Green
Write-Host "  Path      : $masterPath"
Write-Host "  Size      : $sizeKB KB"
Write-Host "  Sections  : $sections"
Write-Host "  Generated : $generated"
Write-Host "  Commit    : $commit"
Write-Host "  Fences    : $fences $(if ($fences % 2 -eq 0) { '(balanced)' } else { '(UNBALANCED - check output)' })" `
    -ForegroundColor $(if ($fences % 2 -eq 0) { 'Gray' } else { 'Red' })
Write-Host "  Damaged   : $damaged $(if ($damaged -eq 0) { '(clean)' } else { '(comment lines became headings)' })" `
    -ForegroundColor $(if ($damaged -eq 0) { 'Gray' } else { 'Red' })

# Warn if the working tree has moved on since the book was generated.
Push-Location -LiteralPath $RepositoryPath
try {
    $head = (& git rev-parse --short HEAD 2>$null)
    if ($head -and $commit -ne 'unknown' -and ([string]$head).Trim() -ne $commit) {
        Write-Host ''
        Write-Warning "Master book was generated at commit $commit but HEAD is $head. Re-run with -Regenerate for a current snapshot."
    }
    $dirty = @(& git status --porcelain 2>$null | Where-Object { $_ -notmatch '^\?\?' })
    if ($dirty.Count -gt 0) {
        Write-Warning "$($dirty.Count) uncommitted change(s) are not reflected in this book."
    }
}
catch { }
finally { Pop-Location }

# --- clipboard -------------------------------------------------------------
if ($ToClipboard) {
    try {
        Set-Clipboard -Value $text
        Write-Host ''
        Write-Host 'Contents copied to clipboard.' -ForegroundColor Green
        Write-Host 'Use Add source > Copied text if the file upload misbehaves.' -ForegroundColor DarkGray
    }
    catch {
        Write-Warning "Could not set clipboard: $($_.Exception.Message)"
    }
}

# --- open windows ----------------------------------------------------------
if (-not $NoExplorer) {
    Start-Process explorer.exe -ArgumentList "/select,`"$masterPath`""
}

if ($NotebookUrl) {
    Start-Process $NotebookUrl
}

# --- the manual part -------------------------------------------------------
Write-Host ''
Write-Host 'Remaining steps in NotebookLM (no API available to script these):' -ForegroundColor Cyan
Write-Host '  1. Sources panel -> find O365Toolkit_MasterBook.md'
Write-Host '  2. Click the three-dot menu -> Remove   (delete BEFORE adding;'
Write-Host '     NotebookLM does not replace by filename, and duplicate copies'
Write-Host '     compete during retrieval)'
Write-Host '  3. Add source -> Upload files -> pick the file selected in Explorer'
Write-Host '  4. Wait for processing, then spot-check with a question only the'
Write-Host '     new content can answer.'
Write-Host ''

return [pscustomobject]@{
    Path      = $masterPath
    SizeKB    = $sizeKB
    Sections  = $sections
    Commit    = $commit
    Generated = $generated
    Balanced  = ($fences % 2 -eq 0)
    Damaged   = $damaged
}
