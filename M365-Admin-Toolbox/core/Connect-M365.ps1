<#
.SYNOPSIS
    Establishes connections to the requested Microsoft 365 services for a given tenant.
.DESCRIPTION
    Dot-sources Common.ps1 and Retry.ps1, loads the tenant's configuration from
    config\tenants.json, ensures the required PowerShell modules are installed, and connects to
    Microsoft Graph, Exchange Online, Purview/IPPS, Microsoft Teams, SharePoint Online, and/or
    Azure based on the switches supplied. Returns a pscustomobject summarizing the tenant that
    was connected to. This exact parameter set is relied upon by nearly every operational script
    in the toolbox and must not change.
.PARAMETER TenantName
    The friendly tenant name as defined in config\tenants.json (mandatory).
.PARAMETER ConnectGraph
    Connect to Microsoft Graph.
.PARAMETER ConnectExchange
    Connect to Exchange Online.
.PARAMETER ConnectPurview
    Connect to Purview / Security & Compliance (IPPS) session.
.PARAMETER ConnectTeams
    Connect to Microsoft Teams.
.PARAMETER ConnectSharePoint
    Connect to the SharePoint Online admin service.
.PARAMETER ConnectAzure
    Connect to Azure via Az.Accounts.
.PARAMETER ConnectIntune
    Connect to Microsoft Graph for Intune operations (uses the same Graph connection).
.PARAMETER UseAppOnly
    Force app-only (certificate-based) authentication for Graph instead of delegated scopes.
.PARAMETER GraphScopes
    Delegated Graph scopes to request when not using app-only authentication.
.EXAMPLE
    . (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName 'Tenant-Example-NA' -ConnectGraph -ConnectExchange
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [switch]$ConnectGraph,
    [switch]$ConnectExchange,
    [switch]$ConnectPurview,
    [switch]$ConnectTeams,
    [switch]$ConnectSharePoint,
    [switch]$ConnectAzure,
    [switch]$ConnectIntune,
    [switch]$UseAppOnly,
    [string[]]$GraphScopes = @(
        'User.Read.All',
        'Directory.ReadWrite.All',
        'Group.ReadWrite.All',
        'AuditLog.Read.All',
        'Device.ReadWrite.All',
        'Organization.Read.All',
        'Mail.ReadWrite',
        'Mail.ReadWrite.Shared'
    )
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Minimum ExchangeOnlineManagement module version required.
$script:ExchangeOnlineManagementMinVersion = '3.9.0'
# Graph request retry/backoff settings (SDK v1.x only - see TODO below).
$script:GraphRequestMaxRetry = 5
$script:GraphRequestRetryDelaySeconds = 10
# Graph API profile version to select (SDK v1.x only - see TODO below).
$script:GraphApiProfile = 'v1.0'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Retry.ps1')
$tenant = Get-TenantConfig -TenantName $TenantName

Ensure-ModuleInstalled -ModuleName 'Microsoft.Graph.Authentication'
if ($ConnectExchange -or $ConnectPurview) { Ensure-ModuleInstalled -ModuleName 'ExchangeOnlineManagement' -MinimumVersion $script:ExchangeOnlineManagementMinVersion }
if ($ConnectTeams) { Ensure-ModuleInstalled -ModuleName 'MicrosoftTeams' }
if ($ConnectSharePoint) { Ensure-ModuleInstalled -ModuleName 'Microsoft.Online.SharePoint.PowerShell' }
if ($ConnectAzure) { Ensure-ModuleInstalled -ModuleName 'Az.Accounts' }

if ($ConnectGraph -or $ConnectIntune) {
    Write-ToolboxLog -TenantName $TenantName -Message 'Connecting to Microsoft Graph.'
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    if ($UseAppOnly -or $tenant.AppRegistration.UseAppOnly) {
        Connect-MgGraph -TenantId $tenant.TenantId -ClientId $tenant.AppRegistration.ClientId -CertificateThumbprint $tenant.AppRegistration.CertificateThumbprint -NoWelcome | Out-Null
    } else {
        Connect-MgGraph -TenantId $tenant.TenantId -Scopes $GraphScopes -NoWelcome | Out-Null
    }
    # TODO: SDK v1/v2 compatibility - Set-MgRequestContext and Select-MgProfile were both
    # removed from the Microsoft.Graph PowerShell SDK v2.x (profile selection is automatic in
    # v2+, and retry/backoff configuration moved to Connect-MgGraph / module-level settings).
    # These calls are wrapped in try/catch so this script does not hard-fail on newer SDK
    # installs where the cmdlets no longer exist. Revisit once the toolbox standardizes on SDK v2.
    try {
        Set-MgRequestContext -MaxRetry $script:GraphRequestMaxRetry -RetryDelay $script:GraphRequestRetryDelaySeconds -ErrorAction Stop
    } catch {
        Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "Set-MgRequestContext not available (likely Graph SDK v2+): $($_.Exception.Message)"
    }
    try {
        Select-MgProfile -Name $script:GraphApiProfile -ErrorAction Stop
    } catch {
        Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "Select-MgProfile not available (likely Graph SDK v2+, profile selection is automatic): $($_.Exception.Message)"
    }
}

if ($ConnectExchange) {
    Write-ToolboxLog -TenantName $TenantName -Message 'Connecting to Exchange Online.'
    Connect-ExchangeOnline -Organization $tenant.ExchangeOrganization -ShowBanner:$false | Out-Null
}

if ($ConnectPurview) {
    Write-ToolboxLog -TenantName $TenantName -Message 'Connecting to Purview / IPPS session.'
    Connect-IPPSSession -Organization $tenant.ExchangeOrganization -EnableSearchOnlySession | Out-Null
}

if ($ConnectTeams) {
    Write-ToolboxLog -TenantName $TenantName -Message 'Connecting to Microsoft Teams.'
    Connect-MicrosoftTeams -TenantId $tenant.TenantId | Out-Null
}

if ($ConnectSharePoint) {
    Write-ToolboxLog -TenantName $TenantName -Message 'Connecting to SharePoint Online admin service.'
    $prefix = $tenant.PrimaryDomain.Split('.')[0]
    Connect-SPOService -Url "https://$prefix-admin.sharepoint.com"
}

if ($ConnectAzure) {
    Write-ToolboxLog -TenantName $TenantName -Message 'Connecting to Azure.'
    Connect-AzAccount -Tenant $tenant.TenantId | Out-Null
}

[pscustomobject]@{
    TenantName = $tenant.Name
    TenantId = $tenant.TenantId
    Domain = $tenant.PrimaryDomain
    ExchangeOrganization = $tenant.ExchangeOrganization
    OnPremEnabled = $tenant.OnPrem.Enabled
    Region = $tenant.Region
    LocationName = $tenant.LocationName
}
