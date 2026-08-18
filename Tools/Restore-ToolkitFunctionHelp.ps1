# Tools/Restore-ToolkitFunctionHelp.ps1
# Track  : NEUTRAL
# Purpose: Restore comment-based help blocks that were lost when a function body
#          was rewritten. Reads the help from a prior git revision and splices it
#          onto the CURRENT body, so code fixes are preserved and only the
#          documentation is recovered.
#          Also reports .PARAMETER entries that no longer match the current
#          parameter list, since a rewritten body may have changed them.
# CHANGE : 2026-08-18 - Initial version. Supports -WhatIf per R2.8.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Files to restore. Default: every Public/Private .ps1 missing .SYNOPSIS.
    [Parameter(Position = 0)]
    [string[]] $Path,

    # Git revision holding the intact help. Default: the previous commit.
    [Parameter()]
    [string] $Ref = 'HEAD~1',

    [Parameter()]
    [string] $RepositoryPath,

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

Push-Location -LiteralPath $RepositoryPath
try {

    # --- target list ------------------------------------------------------
    $targets = @()
    if ($Path) {
        $targets = @($Path)
    }
    else {
        $candidates = @(Get-ChildItem -LiteralPath $RepositoryPath -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '[\\/](Public|Private)[\\/]' } |
            Where-Object { $_.Length -gt 0 })

        foreach ($c in $candidates) {
            $body = Get-Content -LiteralPath $c.FullName -Raw
            if ($body -notmatch '\.SYNOPSIS') {
                $rel = $c.FullName.Substring($RepositoryPath.Length).TrimStart('\', '/').Replace('\', '/')
                $targets += $rel
            }
        }
    }

    if ($targets.Count -eq 0) {
        Write-Host 'No files missing comment-based help.' -ForegroundColor Green
        return
    }

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($rel in $targets) {

        $relGit  = $rel.Replace('\', '/')
        $full    = Join-Path -Path $RepositoryPath -ChildPath $relGit.Replace('/', '\')

        if (-not (Test-Path -LiteralPath $full)) {
            Write-Warning "Not found on disk: $rel"
            continue
        }

        # --- fetch the old revision ---------------------------------------
        $oldText = & git show "${Ref}:${relGit}" 2>$null | Out-String
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($oldText)) {
            Write-Warning "Could not read ${Ref}:${relGit}"
            continue
        }
        if ($oldText -notmatch '\.SYNOPSIS') {
            Write-Warning "No help block in ${Ref}:${relGit} - skipped"
            continue
        }

        # --- locate the help comment token in the old text ----------------
        $oldTokens = $null; $oldErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            $oldText, [ref] $oldTokens, [ref] $oldErrors)

        $helpToken = $null
        foreach ($tok in @($oldTokens)) {
            if ($tok.Kind -ne 'Comment') { continue }
            if ($tok.Text -match '\.SYNOPSIS') { $helpToken = $tok; break }
        }
        if (-not $helpToken) {
            Write-Warning "Help token not found in ${Ref}:${relGit} - skipped"
            continue
        }
        $helpText = $helpToken.Text.TrimEnd()

        # --- locate the insertion point in the current text ---------------
        $curText   = Get-Content -LiteralPath $full -Raw
        $curTokens = $null; $curErrors = $null
        $curAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $curText, [ref] $curTokens, [ref] $curErrors)

        if (@($curErrors).Count -gt 0) {
            Write-Warning "Current file has parse errors, skipping: $rel"
            continue
        }

        $functions = @($curAst.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        if ($functions.Count -eq 0) {
            Write-Warning "No function definition found in $rel - skipped"
            continue
        }

        $fn = $functions[0]
        $insertAt = $fn.Extent.StartOffset

        # Preserve the indentation of the function keyword.
        $lineStart = $curText.LastIndexOf("`n", [Math]::Max($insertAt - 1, 0)) + 1
        $indent = ''
        if ($insertAt -gt $lineStart) {
            $indent = $curText.Substring($lineStart, $insertAt - $lineStart)
            if ($indent -notmatch '^\s*$') { $indent = '' }
        }

        $indentedHelp = ($helpText -split "`r?`n" | ForEach-Object { "$indent$_" }) -join "`r`n"
        $newText = $curText.Substring(0, $lineStart) +
                   $indentedHelp + "`r`n" +
                   $curText.Substring($lineStart)

        # --- never write a file we just broke -----------------------------
        $vTokens = $null; $vErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            $newText, [ref] $vTokens, [ref] $vErrors)
        if (@($vErrors).Count -gt 0) {
            Write-Warning "Restore would break $rel - skipped. First: $(@($vErrors)[0].Message)"
            continue
        }

        # --- compare .PARAMETER entries to the current parameter list -----
        $helpParams = @()
        foreach ($m in [regex]::Matches($helpText, '(?im)^\s*\.PARAMETER\s+(\w+)')) {
            $helpParams += $m.Groups[1].Value
        }

        $actualParams = @()
        if ($fn.Body -and $fn.Body.ParamBlock) {
            foreach ($p in @($fn.Body.ParamBlock.Parameters)) {
                $actualParams += $p.Name.VariablePath.UserPath
            }
        }

        $documentedButGone = @($helpParams   | Where-Object { $actualParams -notcontains $_ })
        $undocumented      = @($actualParams | Where-Object { $helpParams   -notcontains $_ })

        if ($PSCmdlet.ShouldProcess($rel, "Restore comment-based help from $Ref")) {
            if ($Backup) { Copy-Item -LiteralPath $full -Destination "$full.bak" -Force }
            Set-Content -LiteralPath $full -Value $newText -Encoding utf8 -NoNewline
        }

        $results.Add([pscustomobject]@{
            File          = $rel
            HelpLines     = @($helpText -split "`r?`n").Count
            StaleParams   = ($documentedButGone -join ', ')
            MissingParams = ($undocumented -join ', ')
        })
    }

    Write-Host ''
    if ($results.Count -eq 0) {
        Write-Host 'Nothing restored.' -ForegroundColor Yellow
    }
    else {
        Write-Host "$($results.Count) file(s) restored from $Ref." -ForegroundColor Green
        $results | Format-Table -AutoSize -Wrap
        Write-Host 'StaleParams   = documented in help but no longer a parameter (delete the .PARAMETER entry).' -ForegroundColor DarkGray
        Write-Host 'MissingParams = a real parameter with no .PARAMETER entry (add one).' -ForegroundColor DarkGray
    }
}
finally {
    Pop-Location
}
