<#
.SYNOPSIS
    Bootstraps the M365 Admin Toolbox in place (without installing it as a module).
.DESCRIPTION
    Imports the M365AdminToolbox module manifest from the current location and
    optionally installs required dependency modules and initializes the local
    secret store used for app-only authentication.
.PARAMETER InstallDependencies
    If specified, ensures all required PowerShell modules are installed.
.PARAMETER InitializeSecretStore
    If specified, initializes the toolbox's local SecretStore vault.
.EXAMPLE
    .\Bootstrap-M365AdminToolbox.ps1 -InstallDependencies -InitializeSecretStore

    Installs all required modules and initializes the secret store.
#>
param(
    [switch]$InstallDependencies,
    [switch]$InitializeSecretStore
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

$root = Split-Path -Parent $MyInvocation.MyCommand.Path

try {
    Import-Module (Join-Path $root 'M365AdminToolbox.psd1') -Force -ErrorAction Stop
} catch {
    Write-Warning "Failed to import M365AdminToolbox.psd1 from '$root'. Ensure the module manifest exists before bootstrapping. Error: $_"
    return
}

if ($InstallDependencies) {
    foreach ($m in $RequiredModules) {
        Ensure-ModuleInstalled -ModuleName $m
    }
}

if ($InitializeSecretStore) {
    Initialize-ToolboxSecretStore
}

Write-Host 'Bootstrap complete.'
