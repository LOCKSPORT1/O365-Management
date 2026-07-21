<#
.SYNOPSIS
    Core shared helper functions for the M365 Admin Toolbox.
.DESCRIPTION
    Provides tenant-neutral utility functions used across the toolbox: resolving the toolbox
    root/config paths, loading tenant configuration from config\tenants.json, ensuring
    directories/modules exist, structured logging, and resolving license SKU IDs via Microsoft
    Graph. This file is dot-sourced by nearly every other script in the toolbox and must keep
    its exported function names and signatures stable.
.PARAMETER N/A
    This file defines functions only; it takes no parameters itself.
.EXAMPLE
    . (Join-Path $PSScriptRoot 'Common.ps1')
    $tenant = Get-TenantConfig -TenantName 'Tenant-Example-NA'
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ToolboxRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Get-ConfigPath {
    return (Join-Path (Get-ToolboxRoot) 'config\tenants.json')
}

function Get-ToolboxConfig {
    $path = Get-ConfigPath
    if (-not (Test-Path $path)) { throw "Config not found: $path" }
    return Get-Content -Path $path -Raw | ConvertFrom-Json
}

function Get-TenantConfig {
    param([Parameter(Mandatory)][string]$TenantName)
    $cfg = Get-ToolboxConfig
    $tenant = $cfg.Tenants | Where-Object { $_.Name -eq $TenantName }
    if (-not $tenant) { throw "Tenant '$TenantName' not found in config." }
    return $tenant
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
}

function Write-ToolboxLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO',
        [string]$TenantName = 'GLOBAL',
        [string]$LogName = 'toolbox.log'
    )
    $root = Get-ToolboxRoot
    $logDir = Join-Path $root 'logs'
    Ensure-Directory -Path $logDir
    $line = "$(Get-Date -Format s) [$Level] [$TenantName] $Message"
    Add-Content -Path (Join-Path $logDir $LogName) -Value $line
    Write-Host $line
}

function Ensure-ModuleInstalled {
    param(
        [Parameter(Mandatory)][string]$ModuleName,
        [string]$MinimumVersion
    )
    $installed = Get-Module -ListAvailable -Name $ModuleName | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $installed) {
        Write-Host "Installing module $ModuleName..."
        Install-Module -Name $ModuleName -Scope CurrentUser -Force -AllowClobber
    } elseif ($MinimumVersion -and ([version]$installed.Version -lt [version]$MinimumVersion)) {
        Write-Host "Updating module $ModuleName to minimum version $MinimumVersion..."
        Install-Module -Name $ModuleName -Scope CurrentUser -Force -AllowClobber
    }
}

function Resolve-ToolboxUserPrincipalName {
    <#
    .SYNOPSIS
        Ensures a UPN/mail value has a domain suffix, defaulting to the tenant's PrimaryDomain.
    .DESCRIPTION
        Accepts either a full UPN ('jdoe@contoso.com') or a bare local part ('jdoe'). If the
        supplied value already contains an '@', it is returned unchanged (so multi-domain tenants
        can still specify an explicit alternate domain when needed). If it does not contain an
        '@', the tenant's config\tenants.json PrimaryDomain is appended automatically.

        This exists so operators (interactive use) and CSV authors (bulk onboarding) don't have to
        remember or manually type/select the correct verified domain for every new user - the
        domain always comes from the tenant config, removing a common source of typos or
        wrong-domain UPNs that later block license assignment.
    .PARAMETER UserPrincipalName
        The raw value supplied by the caller - either a full UPN or a bare local part (e.g. the
        part before the '@').
    .PARAMETER Tenant
        The tenant config object returned by Get-TenantConfig.
    .EXAMPLE
        $tenant = Get-TenantConfig -TenantName 'Contoso'
        Resolve-ToolboxUserPrincipalName -UserPrincipalName 'jdoe' -Tenant $tenant
        # returns 'jdoe@contoso.com' (assuming PrimaryDomain = 'contoso.com')
    #>
    param(
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [Parameter(Mandatory)]$Tenant
    )
    if ($UserPrincipalName -notmatch '@') {
        return "$UserPrincipalName@$($Tenant.PrimaryDomain)"
    }
    return $UserPrincipalName
}

function Resolve-LicenseSkuIds {
    param(
        [Parameter(Mandatory)][string[]]$SkuPartNumbers
    )
    $subscribed = Get-MgSubscribedSku
    $resolved = foreach ($sku in $SkuPartNumbers) {
        $match = $subscribed | Where-Object { $_.SkuPartNumber -eq $sku }
        if ($match) { $match.SkuId }
    }
    return @($resolved)
}
