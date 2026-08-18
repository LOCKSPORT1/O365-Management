# Tools/Find-ToolkitStatementAssignment.ps1
# Track  : NEUTRAL
# Purpose: Find assignments whose right-hand side is a statement
#          (if/switch/foreach/for/while/do/try) rather than an expression.
#          PowerShell unrolls statement output, so a zero-element result
#          collapses to $null and defeats an inner @() guard:
#              $x = if ($true) { @() }   ->   $x is $null
#          v2 adds consumption analysis so scalar assignments (the safe,
#          ternary-style majority) are separated from real hazards.
# CHANGE : 2026-08-18 - v2. Added collection/scalar classification and
#          downstream-consumption detection. Fixed duplicate output (v1 both
#          formatted and returned). Removed this script's own R3.9 violations.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $RepositoryPath,

    [Parameter()]
    [switch] $IncludeTests,

    [Parameter()]
    [ValidateSet('All', 'HIGH', 'MEDIUM')]
    [string] $MinimumRisk = 'MEDIUM',

    # Emit objects to the pipeline instead of printing a table.
    [Parameter()]
    [switch] $PassThru
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

    # R3.9: initialize then assign, never `= if (...)`
    $RepositoryPath = (Get-Location).Path
    if ($found) { $RepositoryPath = $found }
}

$RepositoryPath = $RepositoryPath.TrimEnd('\', '/')

# --- statement types that can appear as an assignment RHS -----------------
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

$files = @(Get-ChildItem -LiteralPath $RepositoryPath -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
if (-not $IncludeTests) {
    $files = @($files | Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' })
}

$findings = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($file in $files) {

    $tokens  = $null
    $errors  = $null
    $fileAst = $null

    try {
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName, [ref] $tokens, [ref] $errors)
    }
    catch {
        Write-Warning "Parse failed: $($file.FullName) - $($_.Exception.Message)"
        continue
    }
    if (-not $fileAst) { continue }

    $assignments = @($fileAst.FindAll(
        { $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))

    foreach ($assignment in $assignments) {

        $right = $assignment.Right
        if (-not $right) { continue }

        # RHS is often wrapped in a PipelineAst - unwrap one level.
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

        # --- can this produce zero elements? ------------------------------
        # Loops always can (zero iterations). Branches only if a branch body
        # contains an array expression or a command/pipeline.
        $producesCollection = $isLoop
        if (-not $producesCollection) {
            $collectionNodes = @($statement.FindAll({
                $args[0] -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                $args[0] -is [System.Management.Automation.Language.ArrayLiteralAst] -or
                $args[0] -is [System.Management.Automation.Language.CommandAst]
            }, $true))
            if ($collectionNodes.Count -gt 0) { $producesCollection = $true }
        }

        # --- what variable is being assigned? -----------------------------
        $varName = $null
        if ($assignment.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $varName = $assignment.Left.VariablePath.UserPath
        }

        # --- is it later consumed in a way that throws on $null? ----------
        $consumers = [System.Collections.Generic.List[string]]::new()
        if ($varName -and $producesCollection) {

            $startLine = $assignment.Extent.StartLineNumber

            # .Count / .Length member access
            $members = @($fileAst.FindAll({
                $args[0] -is [System.Management.Automation.Language.MemberExpressionAst]
            }, $true))
            foreach ($m in $members) {
                if ($m.Extent.StartLineNumber -lt $startLine) { continue }
                if ($m.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
                if ($m.Expression.VariablePath.UserPath -ne $varName) { continue }
                $memberName = [string] $m.Member.Value
                if ($memberName -eq 'Count' -or $memberName -eq 'Length') {
                    $consumers.Add(".$memberName L$($m.Extent.StartLineNumber)")
                }
            }

            # indexing $var[...]
            $indexes = @($fileAst.FindAll({
                $args[0] -is [System.Management.Automation.Language.IndexExpressionAst]
            }, $true))
            foreach ($ix in $indexes) {
                if ($ix.Extent.StartLineNumber -lt $startLine) { continue }
                if ($ix.Target -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
                if ($ix.Target.VariablePath.UserPath -eq $varName) {
                    $consumers.Add("index L$($ix.Extent.StartLineNumber)")
                }
            }
        }

        # --- classify -----------------------------------------------------
        $risk = 'SAFE'
        if ($producesCollection) {
            $risk = 'MEDIUM'
            if ($consumers.Count -gt 0) { $risk = 'HIGH' }
        }

        $relative = $file.FullName
        if ($file.FullName.StartsWith($RepositoryPath, [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $file.FullName.Substring($RepositoryPath.Length).TrimStart('\', '/')
        }

        $snippet = ($assignment.Extent.Text -split "`r?`n")[0].Trim()
        if ($snippet.Length -gt 60) { $snippet = $snippet.Substring(0, 60) + '...' }

        $findings.Add([pscustomobject]@{
            Risk     = $risk
            File     = $relative
            Line     = $assignment.Extent.StartLineNumber
            Variable = $varName
            Consumed = ($consumers -join ', ')
            Code     = $snippet
        })
    }
}

# --- filter and report ----------------------------------------------------
$ranking = @{ 'HIGH' = 3; 'MEDIUM' = 2; 'SAFE' = 1 }

$threshold = 0
if ($MinimumRisk -ne 'All') { $threshold = $ranking[$MinimumRisk] }

$shown = @($findings | Where-Object { $ranking[$_.Risk] -ge $threshold })

if ($PassThru) {
    return $shown
}

$high   = @($findings | Where-Object { $_.Risk -eq 'HIGH' })
$medium = @($findings | Where-Object { $_.Risk -eq 'MEDIUM' })
$safe   = @($findings | Where-Object { $_.Risk -eq 'SAFE' })

Write-Host ''
Write-Host "R3.9 scan: $($findings.Count) statement-expression assignment(s)" -ForegroundColor Cyan
Write-Host "  HIGH   $($high.Count)`t- collection-producing AND consumed via .Count/.Length/index. Fix these." -ForegroundColor Red
Write-Host "  MEDIUM $($medium.Count)`t- collection-producing, no risky consumption found. Fix opportunistically." -ForegroundColor Yellow
Write-Host "  SAFE   $($safe.Count)`t- every branch yields a scalar. No action needed." -ForegroundColor DarkGray
Write-Host ''

if ($shown.Count -gt 0) {
    $shown |
        Sort-Object -Property @{ Expression = { $ranking[$_.Risk] }; Descending = $true }, File, Line |
        Format-Table -Property Risk, File, Line, Variable, Consumed, Code -AutoSize -Wrap
}
