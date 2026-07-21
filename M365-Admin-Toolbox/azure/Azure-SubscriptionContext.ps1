<#
.SYNOPSIS
    Sets the active Azure subscription context for a tenant.
.DESCRIPTION
    Connects to Azure for the specified tenant and sets the Az PowerShell context to
    a specific subscription (if provided) or the first available subscription. Throws
    a clear error if no subscription can be resolved.
.PARAMETER TenantName
    The name of the tenant as defined in config\tenants.json.
.PARAMETER SubscriptionId
    Optional. The Azure subscription ID to set as the active context. If omitted, the
    first subscription returned by Get-AzSubscription is used.
.EXAMPLE
    .\Azure-SubscriptionContext.ps1 -TenantName 'Tenant-Example-NA'

    Connects to Azure for Tenant-Example-NA and sets the context to the first available subscription.
.EXAMPLE
    .\Azure-SubscriptionContext.ps1 -TenantName 'Tenant-Example-NA' -SubscriptionId '00000000-0000-0000-0000-000000000000'

    Connects to Azure for Tenant-Example-NA and sets the context to the specified subscription.
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$SubscriptionId
)

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectAzure

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
} else {
    $sub = Get-AzSubscription | Select-Object -First 1
    if ($sub) {
        Set-AzContext -SubscriptionId $sub.Id | Out-Null
    } else {
        throw "No Azure subscriptions were found for tenant '$TenantName' and no -SubscriptionId was specified. Verify the connected account has access to at least one subscription."
    }
}

$ctx = Get-AzContext
Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Azure context set to subscription $($ctx.Subscription.Id)"
$ctx
