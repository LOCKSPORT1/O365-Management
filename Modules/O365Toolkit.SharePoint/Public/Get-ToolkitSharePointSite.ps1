<#
.SYNOPSIS
    Retrieves SharePoint Online site collections from Microsoft Graph.
.DESCRIPTION
    Queries the Microsoft Graph v1.0/sites endpoint.
    Supports querying all sites, searching by site title/keyword, retrieving
    the root tenant site, or retrieving a specific site by SiteId or hostname/relative path.
.PARAMETER SiteId
    The unique composite Site ID (e.g. 'contoso.sharepoint.com,guid1,guid2').
.PARAMETER Search
    Search keyword to match against site names and descriptions.
.PARAMETER Root
    Switch to query the root SharePoint site for the tenant.
.PARAMETER Top
    The maximum number of items to return in a single page.
.PARAMETER AllPages
    Retrieves all pages of results automatically via @odata.nextLink.
.PARAMETER Config
    Optional configuration hashtable containing environment settings.
.OUTPUTS
    [pscustomobject]
.EXAMPLE
    Get-ToolkitSharePointSite -AllPages
.EXAMPLE
    Get-ToolkitSharePointSite -Root
.EXAMPLE
    Get-ToolkitSharePointSite -Search 'Engineering'
.NOTES
    Required Microsoft Graph Scopes:
      - Sites.Read.All
#>
function Get-ToolkitSharePointSite {
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ById', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SiteId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Root')]
        [switch]$Root,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string]$Search,

        [Parameter(ParameterSetName = 'List')]
        [ValidateRange(1, 999)]
        [int]$Top,

        [Parameter(ParameterSetName = 'List')]
        [switch]$AllPages,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Config = @{ Environment = 'Global' }
    )

    Assert-ToolkitGraphConnection
    if (-not $Config) { $Config = @{ Environment = 'Global' } }

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $relativeUri = "v1.0/sites/$SiteId"
        $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config
        $site = Invoke-ToolkitGraphRequest -Uri $requestUri -Method 'GET' -Config $Config

        if ($site) {
            [PSCustomObject]@{
                Id               = $site.id
                DisplayName      = if ($site.PSObject.Properties['displayName']) { $site.displayName } else { $null }
                Name             = if ($site.PSObject.Properties['name']) { $site.name } else { $null }
                WebUrl           = if ($site.PSObject.Properties['webUrl']) { $site.webUrl } else { $null }
                CreatedDateTime  = if ($site.PSObject.Properties['createdDateTime']) { $site.createdDateTime } else { $null }
                LastModifiedTime = if ($site.PSObject.Properties['lastModifiedDateTime']) { $site.lastModifiedDateTime } else { $null }
                SiteCollection   = if ($site.PSObject.Properties['siteCollection']) { $site.siteCollection } else { $null }
                Root             = if ($site.PSObject.Properties['root']) { $site.root } else { $null }
            }
        }
        return
    }

    if ($PSCmdlet.ParameterSetName -eq 'Root') {
        $relativeUri = 'v1.0/sites/root'
        $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config
        $rootSite = Invoke-ToolkitGraphRequest -Uri $requestUri -Method 'GET' -Config $Config

        if ($rootSite) {
            [PSCustomObject]@{
                Id               = $rootSite.id
                DisplayName      = if ($rootSite.PSObject.Properties['displayName']) { $rootSite.displayName } else { $null }
                Name             = if ($rootSite.PSObject.Properties['name']) { $rootSite.name } else { $null }
                WebUrl           = if ($rootSite.PSObject.Properties['webUrl']) { $rootSite.webUrl } else { $null }
                CreatedDateTime  = if ($rootSite.PSObject.Properties['createdDateTime']) { $rootSite.createdDateTime } else { $null }
                LastModifiedTime = if ($rootSite.PSObject.Properties['lastModifiedDateTime']) { $rootSite.lastModifiedDateTime } else { $null }
                SiteCollection   = if ($rootSite.PSObject.Properties['siteCollection']) { $rootSite.siteCollection } else { $null }
                Root             = if ($rootSite.PSObject.Properties['root']) { $rootSite.root } else { $null }
            }
        }
        return
    }

    $relativeUri = 'v1.0/sites'
    $queryParams = [System.Collections.Generic.List[string]]::new()

    if ($Search) {
        $escapedSearch = [System.Uri]::EscapeDataString($Search)
        $queryParams.Add("search=$escapedSearch")
    }

    if ($PSBoundParameters.ContainsKey('Top') -and $Top -gt 0) {
        $queryParams.Add("`$top=$Top")
    }

    if ($queryParams.Count -gt 0) {
        $relativeUri += '?' + ($queryParams -join '&')
    }

    $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config
    $sites = Invoke-ToolkitGraphRequest -Uri $requestUri -Method 'GET' -Config $Config -AllPages:$AllPages.IsPresent

    foreach ($s in $sites) {
        [PSCustomObject]@{
            Id               = $s.id
            DisplayName      = if ($s.PSObject.Properties['displayName']) { $s.displayName } else { $null }
            Name             = if ($s.PSObject.Properties['name']) { $s.name } else { $null }
            WebUrl           = if ($s.PSObject.Properties['webUrl']) { $s.webUrl } else { $null }
            CreatedDateTime  = if ($s.PSObject.Properties['createdDateTime']) { $s.createdDateTime } else { $null }
            LastModifiedTime = if ($s.PSObject.Properties['lastModifiedDateTime']) { $s.lastModifiedDateTime } else { $null }
            SiteCollection   = if ($s.PSObject.Properties['siteCollection']) { $s.siteCollection } else { $null }
            Root             = if ($s.PSObject.Properties['root']) { $s.root } else { $null }
        }
    }
}
