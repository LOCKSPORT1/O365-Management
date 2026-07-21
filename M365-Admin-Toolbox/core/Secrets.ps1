<#
.SYNOPSIS
    Secret storage helpers backed by Microsoft.PowerShell.SecretManagement / SecretStore.
.DESCRIPTION
    Ensures the required SecretManagement/SecretStore modules are installed, registers a local
    default secret vault for the toolbox, and provides Set-ToolboxSecret / Get-ToolboxSecret
    wrappers for storing and retrieving secrets from that vault.
.PARAMETER N/A
    This file defines Ensure-SecretModules, Initialize-ToolboxSecretStore, Set-ToolboxSecret, and
    Get-ToolboxSecret; see those functions' own parameters below.
.EXAMPLE
    . (Join-Path $PSScriptRoot '..\core\Secrets.ps1')
    Set-ToolboxSecret -Name 'AppClientSecret' -Secret $secureString
    $secret = Get-ToolboxSecret -Name 'AppClientSecret'
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Name of the SecretManagement vault used to store toolbox secrets.
$script:ToolboxSecretVaultName = 'ToolboxSecretStore'

function Ensure-SecretModules {
    Ensure-ModuleInstalled -ModuleName 'Microsoft.PowerShell.SecretManagement'
    Ensure-ModuleInstalled -ModuleName 'Microsoft.PowerShell.SecretStore'
}

function Initialize-ToolboxSecretStore {
    Ensure-SecretModules
    if (-not (Get-SecretVault -Name $script:ToolboxSecretVaultName -ErrorAction SilentlyContinue)) {
        Register-SecretVault -Name $script:ToolboxSecretVaultName -ModuleName 'Microsoft.PowerShell.SecretStore' -DefaultVault
    }
}

function Set-ToolboxSecret {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object]$Secret
    )
    Initialize-ToolboxSecretStore
    Set-Secret -Name $Name -Secret $Secret -Vault $script:ToolboxSecretVaultName
}

function Get-ToolboxSecret {
    param([Parameter(Mandatory)][string]$Name)
    Initialize-ToolboxSecretStore
    return Get-Secret -Name $Name -Vault $script:ToolboxSecretVaultName
}
