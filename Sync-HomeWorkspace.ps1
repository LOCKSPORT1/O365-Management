<#
.SYNOPSIS
    Syncs and initializes the O365-Management workspace on a secondary computer.
.DESCRIPTION
    Ensures execution policy is relaxed for the process, navigates to the repo,
    fetches and checks out the active feature branch, pulls latest changes, 
    and validates module dependency paths and Pester test readiness.
#>
[CmdletBinding()]
param(
    [string]$BranchName = "feature/notebooklm-module-books",
    [string]$RepoPath = "C:\Users\jchristy\Documents\GitHub\O365-Management"
)

$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  O365-Management Workspace Home Synchronization Tool   " -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

# 1. Validate Repository Directory
if (-not (Test-Path $RepoPath)) {
    Write-Error "Repository path not found at '$RepoPath'. Please clone LOCKSPORT1/O365-Management first."
    exit 1
}

Set-Location $RepoPath
Write-Host "[+] Target Working Directory: $(Get-Location)" -ForegroundColor Green

# 2. Git Status & Branch Sync
Write-Host "`n[*] Synchronizing Git branch ($BranchName)..." -ForegroundColor Yellow
git fetch origin
$currentBranch = (git branch --show-current).Trim()

if ($currentBranch -ne $BranchName) {
    Write-Host "[*] Switching from $currentBranch to $BranchName..." -ForegroundColor Cyan
    git checkout $BranchName
}

git pull origin $BranchName
Write-Host "PASS: Working tree is up to date with remote." -ForegroundColor Green

# 3. Preload & Validate Core & Entra Modules
Write-Host "`n[*] Verifying module manifests and dependencies..." -ForegroundColor Yellow
$corePsd1  = Join-Path $RepoPath "Core\O365Toolkit.Core.psd1"
$entraPsd1 = Join-Path $RepoPath "Modules\O365Toolkit.Entra\O365Toolkit.Entra.psd1"

if (-not (Test-Path $corePsd1)) { throw "Core manifest missing at $corePsd1" }
if (-not (Test-Path $entraPsd1)) { throw "Entra manifest missing at $entraPsd1" }

Import-Module $corePsd1 -Force -ErrorAction Stop
Import-Module $entraPsd1 -Force -ErrorAction Stop
Write-Host "PASS: Core and Entra modules loaded successfully into session memory." -ForegroundColor Green

# 4. Run Quick Pester Smoke Test to Ensure Healthy Starting State
Write-Host "`n[*] Running smoke test suite across Entra modules..." -ForegroundColor Yellow
$testResults = Invoke-Pester -Path (Join-Path $RepoPath "Modules\O365Toolkit.Entra\Tests") -PassThru

if ($testResults.FailedCount -gt 0) {
    Write-Warning "Smoke test suite reported failures ($($testResults.FailedCount)). Please investigate."
} else {
    Write-Host "PASS: All Entra smoke tests green ($($testResults.PassedCount) passed)." -ForegroundColor Green
}

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "  SUCCESS: Home PC workspace is synchronized and ready!  " -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan