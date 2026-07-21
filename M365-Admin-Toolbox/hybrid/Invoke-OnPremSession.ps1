<#
.SYNOPSIS
    Runs a script block against a tenant's on-prem AD host via PowerShell remoting.

.DESCRIPTION
    Shared helper used by the hybrid AD scripts (New-HybridADUser, Disable-HybridADUser,
    Start-ADSync, etc.) to open a PSSession to the tenant's configured on-prem
    domain controller / management host (OnPrem.RemoteHost in tenants.json) and execute
    a supplied script block there. Centralizes session setup/teardown, credential
    handling, and retry behavior so callers don't duplicate remoting logic.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json. Used to look up the
    OnPrem.RemoteHost, and to confirm the tenant is enabled for on-prem operations.

.PARAMETER ScriptBlock
    The script block to execute on the remote on-prem host. Must accept parameters
    matching -ArgumentList (declared via a param() block at the top of the script block).

.PARAMETER ArgumentList
    Positional arguments passed through to the remote script block.

.PARAMETER Credential
    Optional PSCredential to use for the remote connection. If omitted, the current
    user's context is used (relies on existing Kerberos/WinRM trust). Never hardcode
    credentials in calling scripts — prompt via Get-Credential or supply a
    pre-built PSCredential from a secure store.

.EXAMPLE
    . (Join-Path $PSScriptRoot 'Invoke-OnPremSession.ps1') -TenantName 'Contoso' -ScriptBlock {
        param($Name)
        Get-ADUser -Identity $Name
    } -ArgumentList @('jdoe')
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [Parameter(Mandatory)][scriptblock]$ScriptBlock,
    [object[]]$ArgumentList,
    [System.Management.Automation.PSCredential]$Credential
)

. (Join-Path $PSScriptRoot '..\core\Common.ps1')

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Number of times to attempt establishing the remote session before giving up
$SessionRetryAttempts = 3
# Seconds to wait between session creation retry attempts
$SessionRetryDelaySeconds = 5

$tenant = Get-TenantConfig -TenantName $TenantName
if (-not $tenant.OnPrem.Enabled) { throw "Tenant $TenantName is not configured for on-prem operations." }
if ([string]::IsNullOrWhiteSpace($tenant.OnPrem.RemoteHost)) { throw "OnPrem.RemoteHost is not configured for $TenantName" }

Import-Module ActiveDirectory -ErrorAction SilentlyContinue
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')

$sessionParams = @{ ComputerName = $tenant.OnPrem.RemoteHost }
if ($Credential) { $sessionParams['Credential'] = $Credential }

$session = $null
try {
    $session = Invoke-WithRetry -TenantName $TenantName -Operation "Connect to on-prem host $($tenant.OnPrem.RemoteHost)" -MaxAttempts $SessionRetryAttempts -BaseDelaySeconds $SessionRetryDelaySeconds -ScriptBlock {
        New-PSSession @sessionParams
    }
    Invoke-Command -Session $session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}
catch {
    Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "On-prem session operation against $($tenant.OnPrem.RemoteHost) failed: $($_.Exception.Message)"
    throw
}
finally {
    if ($session) { Remove-PSSession -Session $session }
}
