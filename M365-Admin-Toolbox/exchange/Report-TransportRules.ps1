<#
.SYNOPSIS
    Reports all Exchange Online mail flow (transport) rules for a tenant.

.DESCRIPTION
    Connects to Exchange Online for the given tenant and exports a CSV listing every transport rule's
    name, state, mode, priority, comments, and description.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. Tenant-Example-NA).

.PARAMETER OutputCsv
    Path to write the resulting CSV report. Defaults to .\reports\TransportRules.csv under the toolbox root.

.EXAMPLE
    .\Report-TransportRules.ps1 -TenantName Tenant-Example-NA -OutputCsv .\reports\Contoso-TransportRules.csv

    Exports all transport rules for the Tenant-Example-NA tenant to the given CSV path.
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$OutputCsv = '.\reports\TransportRules.csv'
)

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectExchange

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

Invoke-ToolboxSafely -TenantName $TenantName -Operation 'Report-TransportRules' -Rethrow -ScriptBlock {
    $rules = Invoke-WithRetry -TenantName $TenantName -Operation 'Get-TransportRule' -ScriptBlock {
        Get-TransportRule
    }
    $rows = foreach ($rule in $rules) {
        [pscustomobject]@{
            TenantName = $TenantName
            Name = $rule.Name
            State = $rule.State
            Mode = $rule.Mode
            Priority = $rule.Priority
            Comments = $rule.Comments
            Description = $rule.Description
        }
    }
    $rows | Export-Csv -NoTypeInformation -Path $OutputCsv
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Transport rule report exported to $OutputCsv"
}
