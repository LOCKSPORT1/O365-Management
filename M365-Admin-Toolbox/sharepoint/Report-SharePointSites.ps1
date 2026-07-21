<#
.SYNOPSIS
Exports a SharePoint Online site inventory for a tenant to CSV.
.DESCRIPTION
Connects to the SharePoint Online admin service for the given tenant and exports key site
properties (URL, title, owner, template, storage usage, lock state, sharing capability) to CSV.
.PARAMETER TenantName
Tenant name from config\tenants.json.
.PARAMETER OutputCsv
Path to write the exported site inventory CSV.
.PARAMETER SiteLimit
Maximum number of sites to retrieve from Get-SPOSite ('All' retrieves every site).
.EXAMPLE
.\sharepoint\Report-SharePointSites.ps1 -TenantName Tenant-Example-NA
.EXAMPLE
.\sharepoint\Report-SharePointSites.ps1 -TenantName Tenant-Example-Cloud -OutputCsv .\reports\SPOSites-Cloud.csv
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$OutputCsv = '.\reports\SharePointSites.csv',
    [string]$SiteLimit = 'All'
)

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectSharePoint

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

try {
    $sites = Get-SPOSite -Limit $SiteLimit
    $rows = foreach ($site in $sites) {
        [pscustomobject]@{
            TenantName = $TenantName
            Url = $site.Url
            Title = $site.Title
            Owner = $site.Owner
            Template = $site.Template
            StorageUsageCurrent = $site.StorageUsageCurrent
            LockState = $site.LockState
            SharingCapability = $site.SharingCapability
        }
    }
    $rows | Export-Csv -NoTypeInformation -Path $OutputCsv
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "SharePoint site inventory exported to $OutputCsv"
}
catch {
    Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "SharePoint site inventory export failed: $($_.Exception.Message)"
    throw
}
