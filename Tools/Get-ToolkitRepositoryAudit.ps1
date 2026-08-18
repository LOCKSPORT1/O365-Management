# Tools/Get-ToolkitRepositoryAudit.ps1
# Track  : NEUTRAL
# Purpose: Full repository audit - git sync state, module/function inventory,
#          comment-based help coverage, manifest export drift, hygiene issues,
#          and a sanitization scan for tenant-identifying strings.
#          Produces a console summary and an optional Markdown report.
# CHANGE : 2026-08-18 - Initial version. R3.9 compliant throughout.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $RepositoryPath,

    # Write a Markdown report. Default: PrivateExports\Repository_Audit.md
    [Parameter()]
    [string] $OutputPath,

    [Parameter()]
    [switch] $NoReport
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

if (-not $OutputPath) {
    $OutputPath = Join-Path $RepositoryPath 'PrivateExports\Repository_Audit.md'
}

Push-Location -LiteralPath $RepositoryPath
try {

$sb = [System.Text.StringBuilder]::new()
function Add-Line { param([string]$Text = '') $null = $sb.AppendLine($Text) }

$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

Add-Line '# Repository Audit'
Add-Line ''
Add-Line "**Repository:** $RepositoryPath  "
Add-Line "**Generated:** $stamp"
Add-Line ''

# =========================================================================
# 1. GIT STATE
# =========================================================================
Write-Host "`n=== 1. GIT STATE ===" -ForegroundColor Cyan

$branch     = (& git rev-parse --abbrev-ref HEAD 2>$null)
$commit     = (& git rev-parse --short HEAD 2>$null)
$commitMsg  = (& git log -1 --pretty=%s 2>$null)
$commitDate = (& git log -1 --pretty=%ci 2>$null)

$null = & git fetch origin --quiet 2>$null

$ahead  = 0
$behind = 0
$counts = (& git rev-list --left-right --count "origin/$branch...$branch" 2>$null)
if ($counts) {
    $parts = @(([string]$counts).Trim() -split '\s+')
    if ($parts.Count -eq 2) {
        $behind = [int]$parts[0]
        $ahead  = [int]$parts[1]
    }
}

$dirty     = @(& git status --porcelain 2>$null)
$modified  = @($dirty | Where-Object { $_ -notmatch '^\?\?' })
$untracked = @($dirty | Where-Object { $_ -match '^\?\?' })

$branches       = @(& git branch --format='%(refname:short)' 2>$null)
$remoteBranches = @(& git branch -r --format='%(refname:short)' 2>$null |
    Where-Object { $_ -notmatch 'HEAD' })
$stashes        = @(& git stash list 2>$null)

$syncState = 'in sync'
if ($ahead -gt 0 -and $behind -gt 0) { $syncState = "DIVERGED (+$ahead / -$behind)" }
elseif ($ahead -gt 0)  { $syncState = "AHEAD by $ahead (unpushed)" }
elseif ($behind -gt 0) { $syncState = "BEHIND by $behind (unpulled)" }

Write-Host "  Branch      : $branch"
Write-Host "  Commit      : $commit  $commitMsg"
Write-Host "  Sync        : $syncState" -ForegroundColor $(if ($syncState -eq 'in sync') { 'Green' } else { 'Yellow' })
Write-Host "  Uncommitted : $($modified.Count) modified, $($untracked.Count) untracked"
Write-Host "  Branches    : $($branches.Count) local, $($remoteBranches.Count) remote"
Write-Host "  Stashes     : $($stashes.Count)"

Add-Line '## 1. Git state'
Add-Line ''
Add-Line "| Item | Value |"
Add-Line "|---|---|"
Add-Line "| Branch | ``$branch`` |"
Add-Line "| Commit | ``$commit`` - $commitMsg |"
Add-Line "| Commit date | $commitDate |"
Add-Line "| Sync with origin | $syncState |"
Add-Line "| Uncommitted changes | $($modified.Count) modified, $($untracked.Count) untracked |"
Add-Line "| Local branches | $($branches -join ', ') |"
Add-Line "| Remote branches | $($remoteBranches -join ', ') |"
Add-Line "| Stashes | $($stashes.Count) |"
Add-Line ''

if ($modified.Count -gt 0) {
    Add-Line '**Uncommitted:**'
    Add-Line '```'
    foreach ($m in $modified) { Add-Line $m }
    Add-Line '```'
    Add-Line ''
}

# =========================================================================
# 2. MODULE AND FUNCTION INVENTORY
# =========================================================================
Write-Host "`n=== 2. MODULE INVENTORY ===" -ForegroundColor Cyan

$moduleRoots = [System.Collections.Generic.List[pscustomobject]]::new()

$coreDir = Join-Path $RepositoryPath 'Core'
if (Test-Path -LiteralPath $coreDir) {
    $moduleRoots.Add([pscustomobject]@{ Name = 'O365Toolkit.Core'; Path = $coreDir })
}

$modulesDir = Join-Path $RepositoryPath 'Modules'
if (Test-Path -LiteralPath $modulesDir) {
    $subs = @(Get-ChildItem -LiteralPath $modulesDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($s in $subs) {
        $moduleRoots.Add([pscustomobject]@{ Name = $s.Name; Path = $s.FullName })
    }
}

$toolsDir = Join-Path $RepositoryPath 'Tools\O365Toolkit.NotebookLM'
if (Test-Path -LiteralPath $toolsDir) {
    $moduleRoots.Add([pscustomobject]@{ Name = 'O365Toolkit.NotebookLM'; Path = $toolsDir })
}

$moduleRows   = [System.Collections.Generic.List[pscustomobject]]::new()
$allFunctions = [System.Collections.Generic.List[pscustomobject]]::new()
$noHelp       = [System.Collections.Generic.List[pscustomobject]]::new()
$driftRows    = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($mod in $moduleRoots) {

    $publicFiles  = @(Get-ChildItem -LiteralPath $mod.Path -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '[\\/]Public[\\/]' })
    $privateFiles = @(Get-ChildItem -LiteralPath $mod.Path -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '[\\/]Private[\\/]' })
    $testFiles    = @(Get-ChildItem -LiteralPath $mod.Path -Filter '*.Tests.ps1' -Recurse -ErrorAction SilentlyContinue)

    foreach ($group in @(
        [pscustomobject]@{ Kind = 'Public';  Files = $publicFiles }
        [pscustomobject]@{ Kind = 'Private'; Files = $privateFiles }
    )) {
        foreach ($file in $group.Files) {

            $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            $hasHelp = $false
            if (-not [string]::IsNullOrWhiteSpace($content)) {
                $hasHelp = $content -match '\.SYNOPSIS'
            }

            $tokens = $null; $errors = $null
            $ast = $null
            try {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                    $file.FullName, [ref]$tokens, [ref]$errors)
            } catch { }

            $fnNames = @()
            if ($ast) {
                $fns = @($ast.FindAll({
                    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
                foreach ($f in $fns) { $fnNames += $f.Name }
            }

            foreach ($n in $fnNames) {
                $allFunctions.Add([pscustomobject]@{
                    Module   = $mod.Name
                    Kind     = $group.Kind
                    Function = $n
                    Help     = $hasHelp
                    File     = $file.FullName.Substring($RepositoryPath.Length).TrimStart('\','/')
                })
            }

            if ($group.Kind -eq 'Public' -and -not $hasHelp) {
                foreach ($n in $fnNames) {
                    $noHelp.Add([pscustomobject]@{ Module = $mod.Name; Function = $n })
                }
            }
        }
    }

    # manifest export drift
    $manifest = @(Get-ChildItem -LiteralPath $mod.Path -Filter '*.psd1' -ErrorAction SilentlyContinue |
        Select-Object -First 1)
    $exported = @()
    if ($manifest.Count -gt 0) {
        try {
            $data = Import-PowerShellDataFile -LiteralPath $manifest[0].FullName -ErrorAction Stop
            if ($data.ContainsKey('FunctionsToExport')) { $exported = @($data.FunctionsToExport) }
        } catch {
            Write-Warning "Could not read manifest for $($mod.Name): $($_.Exception.Message)"
        }
    }

    $publicFnNames = @($allFunctions |
        Where-Object { $_.Module -eq $mod.Name -and $_.Kind -eq 'Public' } |
        ForEach-Object { $_.Function })

    $exportedNotFound = @($exported | Where-Object { $_ -ne '*' -and $publicFnNames -notcontains $_ })
    $foundNotExported = @($publicFnNames | Where-Object { $exported -notcontains $_ -and $exported -notcontains '*' })

    if ($exportedNotFound.Count -gt 0 -or $foundNotExported.Count -gt 0) {
        $driftRows.Add([pscustomobject]@{
            Module          = $mod.Name
            ExportedMissing = ($exportedNotFound -join ', ')
            NotExported     = ($foundNotExported -join ', ')
        })
    }

    $moduleRows.Add([pscustomobject]@{
        Module   = $mod.Name
        Public   = $publicFiles.Count
        Private  = $privateFiles.Count
        Tests    = $testFiles.Count
        Exported = $exported.Count
    })
}

$moduleRows | Format-Table -AutoSize

Add-Line '## 2. Module inventory'
Add-Line ''
Add-Line '| Module | Public files | Private files | Test files | Exported |'
Add-Line '|---|---|---|---|---|'
foreach ($r in $moduleRows) {
    Add-Line "| $($r.Module) | $($r.Public) | $($r.Private) | $($r.Tests) | $($r.Exported) |"
}
Add-Line ''

# =========================================================================
# 3. FUNCTION LIST
# =========================================================================
$publicFns  = @($allFunctions | Where-Object { $_.Kind -eq 'Public' }  | Sort-Object Module, Function)
$privateFns = @($allFunctions | Where-Object { $_.Kind -eq 'Private' } | Sort-Object Module, Function)

Write-Host "`n=== 3. FUNCTIONS ===" -ForegroundColor Cyan
Write-Host "  $($publicFns.Count) public, $($privateFns.Count) private"

Add-Line '## 3. Functions'
Add-Line ''
Add-Line "**Public ($($publicFns.Count))**"
Add-Line ''
Add-Line '| Module | Function | Help | File |'
Add-Line '|---|---|---|---|'
foreach ($f in $publicFns) {
    $h = if ($f.Help) { 'yes' } else { '**NO**' }
    Add-Line "| $($f.Module) | ``$($f.Function)`` | $h | ``$($f.File)`` |"
}
Add-Line ''
Add-Line "**Private ($($privateFns.Count))**"
Add-Line ''
Add-Line '| Module | Function | Help |'
Add-Line '|---|---|---|'
foreach ($f in $privateFns) {
    $h = if ($f.Help) { 'yes' } else { 'no' }
    Add-Line "| $($f.Module) | ``$($f.Function)`` | $h |"
}
Add-Line ''

# =========================================================================
# 4. STANDALONE SCRIPTS
# =========================================================================
$standalone = @(Get-ChildItem -LiteralPath $RepositoryPath -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FullName -notmatch '[\\/](Public|Private|Tests)[\\/]' -and
        $_.FullName -notmatch '[\\/]PrivateExports[\\/]'
    } | Sort-Object FullName)

Write-Host "`n=== 4. STANDALONE SCRIPTS ===" -ForegroundColor Cyan
Write-Host "  $($standalone.Count) scripts outside module folders"

Add-Line '## 4. Standalone scripts'
Add-Line ''
Add-Line '| Script | KB |'
Add-Line '|---|---|'
foreach ($s in $standalone) {
    $rel = $s.FullName.Substring($RepositoryPath.Length).TrimStart('\','/')
    Add-Line "| ``$rel`` | $([math]::Round($s.Length/1KB,1)) |"
}
Add-Line ''

# =========================================================================
# 5. HYGIENE
# =========================================================================
Write-Host "`n=== 5. HYGIENE ===" -ForegroundColor Cyan

$allPs1  = @(Get-ChildItem -LiteralPath $RepositoryPath -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
$empty   = @($allPs1 | Where-Object { $_.Length -eq 0 })
$baks    = @(Get-ChildItem -LiteralPath $RepositoryPath -Filter '*.bak' -Recurse -ErrorAction SilentlyContinue)

$parseFails = [System.Collections.Generic.List[string]]::new()
foreach ($f in $allPs1) {
    if ($f.Length -eq 0) { continue }
    $t = $null; $e = $null
    try {
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
        if (@($e).Count -gt 0) {
            $parseFails.Add($f.FullName.Substring($RepositoryPath.Length).TrimStart('\','/'))
        }
    } catch {
        $parseFails.Add($f.FullName.Substring($RepositoryPath.Length).TrimStart('\','/'))
    }
}

$r39High = 'not run'
$scanner = Join-Path $RepositoryPath 'Tools\Find-ToolkitStatementAssignment.ps1'
if (Test-Path -LiteralPath $scanner) {
    try {
        $r39 = @(& $scanner -RepositoryPath $RepositoryPath -MinimumRisk HIGH -PassThru)
        $r39High = "$($r39.Count)"
    } catch {
        $r39High = "error: $($_.Exception.Message)"
    }
}

Write-Host "  Total .ps1        : $($allPs1.Count)"
Write-Host "  Zero-byte files   : $($empty.Count)"       -ForegroundColor $(if ($empty.Count) { 'Yellow' } else { 'Green' })
Write-Host "  .bak files        : $($baks.Count)"        -ForegroundColor $(if ($baks.Count) { 'Yellow' } else { 'Green' })
Write-Host "  Parse failures    : $($parseFails.Count)"  -ForegroundColor $(if ($parseFails.Count) { 'Red' } else { 'Green' })
Write-Host "  R3.9 HIGH         : $r39High"
Write-Host "  Public w/o help   : $($noHelp.Count)"      -ForegroundColor $(if ($noHelp.Count) { 'Yellow' } else { 'Green' })
Write-Host "  Manifest drift    : $($driftRows.Count) module(s)" -ForegroundColor $(if ($driftRows.Count) { 'Yellow' } else { 'Green' })

Add-Line '## 5. Hygiene'
Add-Line ''
Add-Line '| Check | Result |'
Add-Line '|---|---|'
Add-Line "| Total .ps1 files | $($allPs1.Count) |"
Add-Line "| Zero-byte .ps1 files | $($empty.Count) |"
Add-Line "| .bak files | $($baks.Count) |"
Add-Line "| Files with parse errors | $($parseFails.Count) |"
Add-Line "| R3.9 HIGH violations | $r39High |"
Add-Line "| Public functions without help | $($noHelp.Count) |"
Add-Line "| Modules with manifest drift | $($driftRows.Count) |"
Add-Line ''

if ($empty.Count -gt 0) {
    Add-Line '**Zero-byte files:**'
    foreach ($f in $empty) { Add-Line "- ``$($f.FullName.Substring($RepositoryPath.Length).TrimStart('\','/'))``" }
    Add-Line ''
}
if ($parseFails.Count -gt 0) {
    Add-Line '**Parse failures:**'
    foreach ($f in $parseFails) { Add-Line "- ``$f``" }
    Add-Line ''
}
if ($noHelp.Count -gt 0) {
    Add-Line '**Public functions missing comment-based help:**'
    foreach ($f in ($noHelp | Sort-Object Module, Function)) {
        Add-Line "- $($f.Module): ``$($f.Function)``"
    }
    Add-Line ''
}
if ($driftRows.Count -gt 0) {
    Add-Line '**Manifest export drift:**'
    Add-Line ''
    Add-Line '| Module | Exported but not found | Found but not exported |'
    Add-Line '|---|---|---|'
    foreach ($d in $driftRows) {
        Add-Line "| $($d.Module) | $($d.ExportedMissing) | $($d.NotExported) |"
    }
    Add-Line ''
}

# =========================================================================
# 6. SANITIZATION SCAN
# =========================================================================
Write-Host "`n=== 6. SANITIZATION ===" -ForegroundColor Cyan

$patterns = @(
    [pscustomobject]@{ Name = 'User profile path'; Pattern = 'C:\\Users\\[A-Za-z0-9._-]+' }
    [pscustomobject]@{ Name = 'GUID';              Pattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' }
    [pscustomobject]@{ Name = 'Email / UPN';       Pattern = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' }
    [pscustomobject]@{ Name = 'onmicrosoft domain';Pattern = '[A-Za-z0-9-]+\.onmicrosoft\.com' }
    [pscustomobject]@{ Name = 'Possible secret';   Pattern = '(?i)(password|secret|apikey|api_key|thumbprint)\s*=\s*[''"][^''"]{8,}' }
)

$sanitizeHits = [System.Collections.Generic.List[pscustomobject]]::new()

$scanFiles = @($allPs1 | Where-Object {
    $_.Length -gt 0 -and $_.FullName -notmatch '[\\/]PrivateExports[\\/]'
})

foreach ($f in $scanFiles) {
    $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $rel = $f.FullName.Substring($RepositoryPath.Length).TrimStart('\','/')

    foreach ($p in $patterns) {
        $matches = @([regex]::Matches($text, $p.Pattern))
        # Placeholder GUIDs and example addresses are fine.
        $real = @($matches | Where-Object {
            $v = $_.Value
            $v -notmatch '^0{8}-0{4}-0{4}-0{4}-0{12}$' -and
            $v -notmatch '(?i)(example\.com|contoso|fabrikam|yourtenant|placeholder|user@domain)'
        })
        if ($real.Count -gt 0) {
            $sanitizeHits.Add([pscustomobject]@{
                File    = $rel
                Type    = $p.Name
                Count   = $real.Count
                Example = ($real[0].Value)
            })
        }
    }
}

Write-Host "  Potential issues  : $($sanitizeHits.Count)" -ForegroundColor $(if ($sanitizeHits.Count) { 'Yellow' } else { 'Green' })
if ($sanitizeHits.Count -gt 0) {
    $sanitizeHits | Sort-Object Type, File | Format-Table -AutoSize -Wrap
}

Add-Line '## 6. Sanitization scan'
Add-Line ''
Add-Line 'Flags strings that may identify a tenant, user, or secret. Placeholder and example values are excluded. Review each - not every hit is a problem.'
Add-Line ''
if ($sanitizeHits.Count -eq 0) {
    Add-Line 'No potential issues found.'
} else {
    Add-Line '| Type | File | Count | Example |'
    Add-Line '|---|---|---|---|'
    foreach ($h in ($sanitizeHits | Sort-Object Type, File)) {
        Add-Line "| $($h.Type) | ``$($h.File)`` | $($h.Count) | ``$($h.Example)`` |"
    }
}
Add-Line ''

# =========================================================================
# WRITE REPORT
# =========================================================================
if (-not $NoReport) {
    $outDir = Split-Path -Path $OutputPath -Parent
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        $null = New-Item -ItemType Directory -Path $outDir -Force
    }
    Set-Content -LiteralPath $OutputPath -Value $sb.ToString() -Encoding utf8
    Write-Host "`nReport written: $OutputPath" -ForegroundColor Green
}

Write-Host ''

}
finally {
    Pop-Location
}
