# Tools/Repair-ToolkitStatementAssignment.ps1
# Track  : NEUTRAL
# Purpose: Wrap statement-expression assignments in @() so a zero-element
#          result cannot collapse to $null (R3.9).
#              $report = foreach (...) { ... }
#          becomes
#              $report = @(foreach (...) { ... })
#          Uses AST character offsets rather than regex, so multi-line blocks,
#          nested braces, and odd indentation are handled exactly.
# CHANGE : 2026-08-18 - Initial version. Supports -WhatIf per R2.8.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string] $RepositoryPath,

    # Limit to specific files (relative or absolute). Default: all HIGH sites.
    [Parameter()]
    [string[]] $Path,

    # Also repair MEDIUM sites (collection-producing, no risky consumer yet).
    [Parameter()]
    [switch] $IncludeMedium,

    [Parameter()]
    [switch] $IncludeTests,

    # Write .bak alongside each modified file.
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

$loopTypes = @(
    [System.Management.Automation.Language.ForEachStatementAst]
    [System.Management.Automation.Language.ForStatementAst]
    [System.Management.Automation.Language.WhileStatementAst]
    [System.Management.Automation.Language.DoWhileStatementAst]
    [System.Management.Automation.Language.DoUntilStatementAst]
)
$branchTypes = @(
    [System.Management.Automation.Language.IfStatementAst]
    [System.Management.Automation.Language.SwitchStatementAst]
    [System.Management.Automation.Language.TryStatementAst]
)

# --- file set -------------------------------------------------------------
$files = @()
if ($Path) {
    foreach ($p in $Path) {
        $resolved = Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue
        if ($resolved) { $files += @(Get-Item -LiteralPath $resolved.Path) }
        else { Write-Warning "Not found: $p" }
    }
}
else {
    $files = @(Get-ChildItem -LiteralPath $RepositoryPath -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
    if (-not $IncludeTests) {
        $files = @($files | Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' })
    }
}

$repaired = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($file in $files) {

    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { continue }

    $tokens  = $null
    $errors  = $null
    $fileAst = $null

    try {
        $fileAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $text, [ref] $tokens, [ref] $errors)
    }
    catch {
        Write-Warning "Parse failed: $($file.FullName)"
        continue
    }
    if (-not $fileAst) { continue }

    $errorList = @($errors)
    if ($errorList.Count -gt 0) {
        Write-Warning "Skipping (pre-existing parse errors): $($file.FullName)"
        continue
    }

    $assignments = @($fileAst.FindAll(
        { $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))

    # Collect edits first; apply back-to-front so offsets stay valid.
    $edits = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($assignment in $assignments) {

        $right = $assignment.Right
        if (-not $right) { continue }

        $inner = $right
        if ($right -is [System.Management.Automation.Language.PipelineAst]) {
            $elements = @($right.PipelineElements)
            if ($elements.Count -eq 1) { $inner = $elements[0] }
        }

        $isLoop   = $false
        $isBranch = $false
        foreach ($t in $loopTypes)   { if ($right -is $t -or $inner -is $t) { $isLoop   = $true; break } }
        foreach ($t in $branchTypes) { if ($right -is $t -or $inner -is $t) { $isBranch = $true; break } }
        if (-not $isLoop -and -not $isBranch) { continue }

        $statement = $right
        if ($inner -ne $right) { $statement = $inner }

        # Only collection-producing sites need the wrapper.
        $producesCollection = $isLoop
        if (-not $producesCollection) {
            $collectionNodes = @($statement.FindAll({
                $args[0] -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                $args[0] -is [System.Management.Automation.Language.ArrayLiteralAst] -or
                $args[0] -is [System.Management.Automation.Language.CommandAst]
            }, $true))
            if ($collectionNodes.Count -gt 0) { $producesCollection = $true }
        }
        if (-not $producesCollection) { continue }

        $varName = $null
        if ($assignment.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $varName = $assignment.Left.VariablePath.UserPath
        }
        if (-not $varName) { continue }

        # Risky consumer downstream?
        $hasConsumer = $false
        $startLine = $assignment.Extent.StartLineNumber

        $members = @($fileAst.FindAll({
            $args[0] -is [System.Management.Automation.Language.MemberExpressionAst] }, $true))
        foreach ($m in $members) {
            if ($m.Extent.StartLineNumber -lt $startLine) { continue }
            if ($m.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            if ($m.Expression.VariablePath.UserPath -ne $varName) { continue }
            $memberName = [string] $m.Member.Value
            if ($memberName -eq 'Count' -or $memberName -eq 'Length') { $hasConsumer = $true; break }
        }
        if (-not $hasConsumer) {
            $indexes = @($fileAst.FindAll({
                $args[0] -is [System.Management.Automation.Language.IndexExpressionAst] }, $true))
            foreach ($ix in $indexes) {
                if ($ix.Extent.StartLineNumber -lt $startLine) { continue }
                if ($ix.Target -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
                if ($ix.Target.VariablePath.UserPath -eq $varName) { $hasConsumer = $true; break }
            }
        }

        if (-not $hasConsumer -and -not $IncludeMedium) { continue }

        $startOffset = $right.Extent.StartOffset
        $endOffset   = $right.Extent.EndOffset
        $original    = $text.Substring($startOffset, $endOffset - $startOffset)

        if ($original.StartsWith('@(')) { continue }   # already wrapped

        $edits.Add([pscustomobject]@{
            Start    = $startOffset
            End      = $endOffset
            Line     = $assignment.Extent.StartLineNumber
            Variable = $varName
            Original = $original
        })
    }

    if ($edits.Count -eq 0) { continue }

    $newText = $text
    foreach ($edit in ($edits | Sort-Object -Property Start -Descending)) {
        $newText = $newText.Substring(0, $edit.Start) +
                   '@(' + $edit.Original + ')' +
                   $newText.Substring($edit.End)
    }

    # Never write a file we just broke.
    $vTokens = $null; $vErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($newText, [ref] $vTokens, [ref] $vErrors)
    $vErrorList = @($vErrors)
    if ($vErrorList.Count -gt 0) {
        Write-Warning "Repair would break $($file.FullName) - skipped. First: $($vErrorList[0].Message)"
        continue
    }

    $target = "$($file.FullName) ($($edits.Count) site(s): lines $(($edits.Line | Sort-Object) -join ', '))"
    if ($PSCmdlet.ShouldProcess($target, 'Wrap statement-expression assignment in @()')) {
        if ($Backup) {
            Copy-Item -LiteralPath $file.FullName -Destination "$($file.FullName).bak" -Force
        }
        Set-Content -LiteralPath $file.FullName -Value $newText -Encoding utf8 -NoNewline
    }

    foreach ($edit in $edits) {
        $repaired.Add([pscustomobject]@{
            File     = $file.FullName.Replace($RepositoryPath, '').TrimStart('\', '/')
            Line     = $edit.Line
            Variable = '$' + $edit.Variable
        })
    }
}

Write-Host ''
if ($repaired.Count -eq 0) {
    Write-Host 'No repairs needed.' -ForegroundColor Green
}
else {
    Write-Host "$($repaired.Count) site(s) wrapped in @()." -ForegroundColor Green
    $repaired | Sort-Object File, Line | Format-Table -AutoSize
}
