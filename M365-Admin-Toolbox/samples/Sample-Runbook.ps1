<#
.SYNOPSIS
Minimal starter sample showing how to connect to a tenant before calling other toolbox scripts.
.DESCRIPTION
Connects to Graph, Exchange, Purview, Azure, and Intune for the given tenant using the shared
connector script, then shows (commented out) examples of calling other operational scripts
against that same tenant. Intended as a copy/paste starting point, not a script meant to be
scheduled as-is.
.PARAMETER TenantName
Tenant name from config\tenants.json to connect to.
.EXAMPLE
.\samples\Sample-Runbook.ps1 -TenantName Tenant-Example-NA
#>
param([string]$TenantName = 'Tenant-Example-NA')

. "$PSScriptRoot\..\core\Connect-M365.ps1" -TenantName $TenantName -ConnectGraph -ConnectExchange -ConnectPurview -ConnectAzure -ConnectIntune

# Example usage only:
# .\exchange\Audit-Mailboxes.ps1 -TenantName $TenantName -SharedOnly -OutputCsv .\reports\SharedMailboxAudit.csv
# .\lifecycle\Disable-UserLifecycle.ps1 -TenantName $TenantName -UserPrincipalName user@example.com -ConvertMailboxToShared -RemoveLicenses -RevokeSessions -DisableDevices
