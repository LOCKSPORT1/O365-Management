# Tools/O365Toolkit.NotebookLM/Private/New-ToolkitModuleBooks.ps1
# Module : O365Toolkit.NotebookLM
# Track  : NEUTRAL
# Purpose: Compile per-module Markdown source books from repository .ps1 files
#          using AST reflection for function and synopsis extraction.
# CHANGE : 2026-08-18 - Fixed recurring "The property 'Count' cannot be found on
#          this object". Root cause: collections were assigned from an `if` used
#          as an EXPRESSION. PowerShell unrolls statement output, so a
#          zero-element result collapses to $null and defeats the @() guard --
#          `$x = if ($true) { @() }` leaves $x as $null. Every such assignment is
#          now initialize-then-conditionally-reassign, which preserves the empty
#          array. Per R3.9 and R3.6.

function New-ToolkitModuleBooks {
    <#
    .SYNOPSIS
        Compiles Markdown source books for each module in the repository.
    .DESCRIPTION
        Walks the Core directory, each folder under Modules, and the NotebookLM
        tools directory, emitting one Markdown book per module containing every
        non-test .ps1 file with its synopsis and defined functions.

        StrictMode-safe: every collection is coerced with @() at the point of
        assignment, so no .Count access can ever land on $null or a scalar.
    .PARAMETER DestinationPath
        Directory that receives the generated .md book files. Created if absent.
    .PARAMETER RepositoryPath
        Repository root. Resolved by walking up from $PSScriptRoot to a .git
        marker when not supplied.
    .PARAMETER Config
        Optional toolkit configuration hashtable.
    .OUTPUTS
        pscustomobject - one per generated book.
    .EXAMPLE
        New-ToolkitModuleBooks -DestinationPath .\Export\ModuleBooks
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('Path')]
        [ValidateNotNullOrEmpty()]
        [string] $DestinationPath,

        [Parameter()]
        [string] $RepositoryPath,

        [Parameter()]
        [AllowNull()]
        [hashtable] $Config = @{ Environment = 'Global' }
    )

    if (-not $Config) { $Config = @{ Environment = 'Global' } }

    # -----------------------------------------------------------------------
    # Resolve repository root (R3.1 - walk up from $PSScriptRoot, never relative)
    # -----------------------------------------------------------------------
    if (-not $RepositoryPath) {
        $current = $PSScriptRoot
        if (-not $current) { $current = (Get-Location).Path }

        $resolvedRoot = $null
        while ($current) {
            if (Test-Path -LiteralPath (Join-Path -Path $current -ChildPath '.git')) {
                $resolvedRoot = $current
                break
            }
            $parent = [System.IO.Path]::GetDirectoryName($current)
            if (-not $parent -or $parent -eq $current) { break }
            $current = $parent
        }

        if ($resolvedRoot) {
            $RepositoryPath = $resolvedRoot
        }
        else {
            $RepositoryPath = (Get-Location).Path
        }
    }

    $RepositoryPath = $RepositoryPath.TrimEnd('\', '/')

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        $null = New-Item -ItemType Directory -Path $DestinationPath -Force
    }

    # -----------------------------------------------------------------------
    # Build the module target list
    # -----------------------------------------------------------------------
    $moduleTargets = [System.Collections.Generic.List[hashtable]]::new()

    # 1. Core module
    $coreDir = Join-Path -Path $RepositoryPath -ChildPath 'Core'
    if (Test-Path -LiteralPath $coreDir) {
        $moduleTargets.Add(@{
            Name        = 'O365Toolkit.Core'
            Index       = '05'
            Path        = $coreDir
            Description = 'Core Graph API execution engine, paging, authentication, request plumbing.'
        })
    }

    # 2. Service modules
    $modulesRoot = Join-Path -Path $RepositoryPath -ChildPath 'Modules'
    if (Test-Path -LiteralPath $modulesRoot) {
        # @() at assignment: Get-ChildItem returns $null for empty, scalar for one.
        $foundModules = @(Get-ChildItem -LiteralPath $modulesRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property Name)

        $indexCounter = 6
        foreach ($mod in $foundModules) {
            $moduleTargets.Add(@{
                Name        = $mod.Name
                Index       = ('{0:D2}' -f $indexCounter)
                Path        = $mod.FullName
                Description = "Workload automation module for $($mod.Name)."
            })
            $indexCounter++
        }
    }

    # 3. NotebookLM compiler tools
    $toolsDir = Join-Path -Path $RepositoryPath -ChildPath 'Tools\O365Toolkit.NotebookLM'
    if (Test-Path -LiteralPath $toolsDir) {
        $moduleTargets.Add(@{
            Name        = 'O365Toolkit.NotebookLM'
            Index       = ('{0:D2}' -f ($moduleTargets.Count + 5))
            Path        = $toolsDir
            Description = 'AST documentation compiler, repository snapshot generator, export pipeline.'
        })
    }

    # -----------------------------------------------------------------------
    # Generate one book per target
    # -----------------------------------------------------------------------
    $generatedBooks = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($target in $moduleTargets) {

        $bookFileName = '{0}_{1}_Module_Source.md' -f $target['Index'], $target['Name']
        $bookFilePath = Join-Path -Path $DestinationPath -ChildPath $bookFileName

        $sb      = [System.Text.StringBuilder]::new()
        $modName = $target['Name']
        $modDesc = $target['Description']
        $genTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

        $null = $sb.AppendLine("# $modName Module Source Book")
        $null = $sb.AppendLine()
        $null = $sb.AppendLine("**Module:** ``$modName``")
        $null = $sb.AppendLine("**Description:** $modDesc")
        $null = $sb.AppendLine("**Generated:** $genTime")
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('---')
        $null = $sb.AppendLine()

        # @() at assignment - never a bare pipeline into a .Count consumer.
        $scriptFiles = @(Get-ChildItem -LiteralPath $target['Path'] -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' } |
            Sort-Object -Property FullName)

        $includedCount = 0

        foreach ($script in $scriptFiles) {

            $content = Get-Content -LiteralPath $script.FullName -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($content)) { continue }

            # ---- AST reflection, fully guarded (R3.6) ----------------------
            $tokens = $null
            $errors = $null
            $ast    = $null

            try {
                $ast = [System.Management.Automation.Language.Parser]::ParseInput(
                    $content, [ref] $tokens, [ref] $errors)
            }
            catch {
                Write-Warning "Parse failed for '$($script.FullName)': $($_.Exception.Message)"
                $ast = $null
            }

            # NEVER assign a collection from an `if` used as an expression.
            # PowerShell unrolls statement output, so a zero-element result
            # collapses to $null and defeats the @() guard:
            #     $x = if ($true) { @() }   ->   $x is $null
            # Initialize first, then conditionally reassign via a subexpression,
            # which preserves the empty array. (R3.9)
            $functions = @()
            if ($ast) {
                $functions = @($ast.FindAll(
                    { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] },
                    $true))
            }

            $commentBlocks = @()
            if ($tokens) {
                $commentBlocks = @($tokens | Where-Object { $_.Kind -eq 'Comment' })
            }

            $synopsis = 'No synopsis available.'
            if ($commentBlocks.Count -gt 0) {
                $firstBlockText = [string] $commentBlocks[0].Text
                $synopsisMatch  = [regex]::Match($firstBlockText, '\.SYNOPSIS\s+([^\r\n]+)')
                if ($synopsisMatch.Success) {
                    $synopsis = $synopsisMatch.Groups[1].Value.Trim()
                }
            }

            # ---- Relative path, guarded against a non-matching prefix ------
            $relativeScriptPath = $script.FullName
            if ($script.FullName.StartsWith($RepositoryPath, [StringComparison]::OrdinalIgnoreCase)) {
                $relativeScriptPath = $script.FullName.Substring($RepositoryPath.Length).TrimStart('\', '/')
            }

            # ---- Emit ------------------------------------------------------
            $null = $sb.AppendLine("## File: ``$relativeScriptPath``")
            $null = $sb.AppendLine("**Synopsis:** $synopsis")
            $null = $sb.AppendLine()

            if ($functions.Count -gt 0) {
                $null = $sb.AppendLine('### Defined Functions')
                foreach ($fn in $functions) {
                    $null = $sb.AppendLine("- ``$($fn.Name)``")
                }
                $null = $sb.AppendLine()
            }

            $null = $sb.AppendLine('```powershell')
            $null = $sb.AppendLine($content.Trim())
            $null = $sb.AppendLine('```')
            $null = $sb.AppendLine()
            $null = $sb.AppendLine('---')
            $null = $sb.AppendLine()

            $includedCount++
        }

        Set-Content -LiteralPath $bookFilePath -Value $sb.ToString() -Encoding utf8 -Force

        $generatedBooks.Add([pscustomobject]@{
            ModuleName = $target['Name']
            BookFile   = $bookFileName
            FilePath   = $bookFilePath
            FileCount  = $includedCount
        })
    }

    # Caller must wrap in @() - the pipeline unrolls this on return.
    return $generatedBooks.ToArray()
}
