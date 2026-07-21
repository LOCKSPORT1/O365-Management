<#
.SYNOPSIS
    Triggers an Entra Connect (AAD Connect) directory sync cycle on a tenant's sync server.

.DESCRIPTION
    Connects to the tenant's configured on-prem sync server (OnPrem.RemoteHost in
    tenants.json, which must be the host running the Entra Connect / AAD Connect
    ADSync service) and invokes Start-ADSyncSyncCycle to kick off a Delta or Initial
    sync cycle. Retries automatically if a sync cycle is already in progress, which
    is a common transient condition.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json. Used to resolve the
    on-prem sync server from the tenant's OnPrem configuration block.

.PARAMETER PolicyType
    The sync cycle type to run: 'Delta' (default, incremental) or 'Initial' (full sync).

.EXAMPLE
    .\Start-ADSync.ps1 -TenantName 'Contoso'

    Triggers a Delta sync cycle on Contoso's configured Entra Connect server.

.EXAMPLE
    .\Start-ADSync.ps1 -TenantName 'Contoso' -PolicyType 'Initial'

    Triggers a full Initial sync cycle.
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [ValidateSet('Delta','Initial')][string]$PolicyType = 'Delta'
)

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Number of times to retry if a sync cycle is already in progress or the call otherwise fails
$SyncRetryAttempts = 3
# Base delay (seconds) between retry attempts (doubles each attempt, capped at 60s by Invoke-WithRetry)
$SyncRetryBaseDelaySeconds = 15

$tenant = Get-TenantConfig -TenantName $TenantName

Invoke-ToolboxSafely -TenantName $TenantName -Operation "Trigger AD sync cycle ($PolicyType)" -Rethrow -ScriptBlock {
    Invoke-WithRetry -TenantName $TenantName -Operation "Start-ADSyncSyncCycle ($PolicyType)" -MaxAttempts $SyncRetryAttempts -BaseDelaySeconds $SyncRetryBaseDelaySeconds -ScriptBlock {
        . (Join-Path $PSScriptRoot 'Invoke-OnPremSession.ps1') -TenantName $TenantName -ScriptBlock {
            param($PolicyType)
            Import-Module ADSync -ErrorAction Stop
            Start-ADSyncSyncCycle -PolicyType $PolicyType
        } -ArgumentList @($PolicyType)
    }
}
