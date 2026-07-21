<#
.SYNOPSIS
    Installs the M365 Admin Toolbox as a PowerShell module.
.DESCRIPTION
    Copies the toolbox source into a target module path (by default the current
    user's PowerShell Modules folder), optionally installs required dependency
    modules, and optionally imports the module afterward.
.PARAMETER InstallPath
    The destination path to install the toolbox to. Defaults to the current user's
    PowerShell Modules directory.
.PARAMETER Force
    If specified, overwrites an existing installation at InstallPath.
.PARAMETER ImportAfterInstall
    If specified, imports the module immediately after installation.
.PARAMETER InstallDependencies
    If specified, ensures all required PowerShell modules are installed.
.EXAMPLE
    .\Install-M365AdminToolbox.ps1 -InstallDependencies -ImportAfterInstall

    Installs the toolbox to the default path, installs dependencies, and imports it.
.EXAMPLE
    .\Install-M365AdminToolbox.ps1 -InstallPath 'C:\Tools\M365AdminToolbox' -Force

    Installs the toolbox to a custom path, overwriting any existing installation.
#>
param(
    [string]$InstallPath = "$HOME\Documents\PowerShell\Modules\M365AdminToolbox",
    [switch]$Force,
    [switch]$ImportAfterInstall,
    [switch]$InstallDependencies
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$RequiredModules = @(
    'Microsoft.Graph.Authentication',
    'ExchangeOnlineManagement',
    'MicrosoftTeams',
    'Microsoft.Online.SharePoint.PowerShell',
    'Az.Accounts',
    'Microsoft.PowerShell.SecretManagement',
    'Microsoft.PowerShell.SecretStore'
)
# ============================================================

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ((Test-Path $InstallPath) -and -not $Force) {
    throw "Install path already exists: $InstallPath. Use -Force to overwrite."
}

if (Test-Path $InstallPath) {
    Remove-Item -Path $InstallPath -Recurse -Force
}
New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $InstallPath -Recurse -Force

if ($InstallDependencies) {
    foreach ($m in $RequiredModules) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber
        }
    }
}

if ($ImportAfterInstall) {
    Import-Module (Join-Path $InstallPath 'M365AdminToolbox.psd1') -Force
}

Write-Host "Installed M365AdminToolbox to $InstallPath"
