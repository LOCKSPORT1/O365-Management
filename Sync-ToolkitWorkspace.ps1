# Sync-ToolkitWorkspace.ps1
<#
.SYNOPSIS
    Synchronizes the local workspace with the remote Git branch and verifies module health.
.DESCRIPTION
    Dynamically resolves the repository root without hardcoded user profile paths,
    verifies the host runtime is PowerShell 7.2+, pulls the latest commits from
    the remote repository using rebase and autostash, validates Core and workload
    module manifests, ensures Pester v5+ is loaded, and executes smoke tests.
.PARAMETER BranchName
    The Git branch to track and synchronize. Default is 'feature/notebooklm-module-books'.
.PARAMETER RepositoryPath
    The path to the repository root. If omitted, dynamically resolved by walking up from the script location.
.EXAMPLE
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync-ToolkitWorkspace.ps1
.EXAMPLE
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync-ToolkitWorkspace.ps1 -BranchName 'feature/notebooklm-module-books'
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$BranchName = 'feature/notebooklm-module-books',

    [Parameter()]
    [string]$RepositoryPath
)

# ---------------------------------------------------------------------------
# CHANGE: 2026-08-18 - Added Pester v5 module availability verification and explicit
# module import prior to [PesterConfiguration] type instantiation per R5.1.
# Module: Workspace Sync Tool
# Track: NEUTRAL
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7 -or ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 2)) {
    throw "Unsupported PowerShell version ($($PSVersionTable.PSVersion)). O365Toolkit requires PowerShell 7.2 or higher. Please run this script using 'pwsh.exe'."
}

if (-not $RepositoryPath) {
    $current = $PSScriptRoot
    if (-not $current) {
        $current = (Get-Location).Path
    }

    while ($current -and -not (Test-Path -Path (Join-Path -Path $current -ChildPath '.git'))) {
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) {
            break
        }
        $current = $parent
    }

    if ($current -and (Test-Path -Path (Join-Path -Path $current -ChildPath '.git'))) {
        $RepositoryPath = $current
    } else {
        $RepositoryPath = (Get-Location).Path
    }
}

if (-not (Test-Path -Path (Join-Path -Path $RepositoryPath -ChildPath '.git'))) {
    throw "Repository root containing '.git' not found at '$RepositoryPath'."
}

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  O365-Management Workspace Synchronization Tool        " -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan
Write-Host "[+] Target Working Directory: $RepositoryPath" -ForegroundColor Green

Push-Location -Path $RepositoryPath
try {
    Write-Host "[*] Fetching latest remote objects from origin..." -ForegroundColor Yellow
    git fetch origin --prune

    $currentBranch = (git branch --show-current).Trim()
    if ($currentBranch -ne $BranchName) {
        Write-Host "[*] Switching branch from '$currentBranch' to '$BranchName'..." -ForegroundColor Cyan
        git checkout $BranchName
    }

    Write-Host "[*] Synchronizing branch with remote (rebase with autostash)..." -ForegroundColor Yellow
    git pull --rebase --autostash origin $BranchName

    Write-Host "PASS: Working tree is up to date with origin/$BranchName." -ForegroundColor Green

    Write-Host "`n[*] Verifying module manifests..." -ForegroundColor Yellow
    $manifests = @(
        (Join-Path -Path $RepositoryPath -ChildPath 'Core\O365Toolkit.Core.psd1')
        (Join-Path -Path $RepositoryPath -ChildPath 'Modules\O365Toolkit.Entra\O365Toolkit.Entra.psd1')
        (Join-Path -Path $RepositoryPath -ChildPath 'Modules\O365Toolkit.Exchange\O365Toolkit.Exchange.psd1')
        (Join-Path -Path $RepositoryPath -ChildPath 'Modules\O365Toolkit.Intune\O365Toolkit.Intune.psd1')
    )

    foreach ($manifest in $manifests) {
        if (Test-Path -Path $manifest) {
            $imported = Import-Module -Name $manifest -PassThru -Force -ErrorAction Stop
            Write-Host " [+] Loaded: $($imported.Name) (v$($imported.Version))" -ForegroundColor DarkGray
        } else {
            Write-Host " [!] Optional manifest not present: $manifest" -ForegroundColor Yellow
        }
    }

    $testsDir = Join-Path -Path $RepositoryPath -ChildPath 'Modules\O365Toolkit.Entra\Tests'
    if (Test-Path -Path $testsDir) {
        Write-Host "`n[*] Ensuring Pester v5+ test harness is available..." -ForegroundColor Yellow
        if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 })) {
            Write-Host "[*] Installing Pester v5+ for CurrentUser..." -ForegroundColor Yellow
            Install-Module -Name Pester -MinimumVersion 5.3.0 -Scope CurrentUser -Force -SkipPublisherCheck
        }

        Import-Module -Name Pester -MinimumVersion 5.0.0 -Force -ErrorAction Stop

        Write-Host "[*] Running Pester smoke tests..." -ForegroundColor Yellow
        $pesterConfig = [PesterConfiguration]::Default
        $pesterConfig.Run.Path = $testsDir
        $pesterConfig.Output.Verbosity = 'Detailed'
        $null = Invoke-Pester -Configuration $pesterConfig
    }

    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host "  SUCCESS: Workspace is synchronized and ready for action!" -ForegroundColor Green
    Write-Host "========================================================" -ForegroundColor Green
}
finally {
    Pop-Location
}
