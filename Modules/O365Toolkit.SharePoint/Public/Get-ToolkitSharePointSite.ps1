# Modules/O365Toolkit.SharePoint/Public/Get-ToolkitSharePointSite.ps1
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

    # ---------------------------------------------------------------------------
    # CHANGE: 2026-08-18 - Initial creation of Get-ToolkitSharePointSite
    # adhering to Graph API v1.0 path rules (R1.1, R1.2), connection assertion (R1.6),
    # locked lexicon (R2.5), and fallback config normalization (R2.2).
    # Module: O365Toolkit.SharePoint
    # Track: NEUTRAL
    # ---------------------------------------------------------------------------

    Assert-ToolkitGraphConnection

    if (-not $Config) {
        $Config = @{ Environment = 'Global' }
    }

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $relativeUri = "v1.0/sites/$SiteId"
        $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config

        $requestParams = @{
            Uri    = $requestUri
            Method = 'GET'
            Config = $Config
        }

        $site = Invoke-ToolkitGraphRequest @requestParams

        if ($site) {
            [PSCustomObject]@{
                Id               = $site.id
                DisplayName      = $site.displayName
                Name             = $site.name
                WebUrl           = $site.webUrl
                CreatedDateTime  = $site.createdDateTime
                LastModifiedTime = $site.lastModifiedDateTime
                SiteCollection   = $site.siteCollection
                Root             = $site.root
            }
        }
        return
    }

    if ($PSCmdlet.ParameterSetName -eq 'Root') {
        $relativeUri = 'v1.0/sites/root'
        $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config

        $requestParams = @{
            Uri    = $requestUri
            Method = 'GET'
            Config = $Config
        }

        $rootSite = Invoke-ToolkitGraphRequest @requestParams

        if ($rootSite) {
            [PSCustomObject]@{
                Id               = $rootSite.id
                DisplayName      = $rootSite.displayName
                Name             = $rootSite.name
                WebUrl           = $rootSite.webUrl
                CreatedDateTime  = $rootSite.createdDateTime
                LastModifiedTime = $rootSite.lastModifiedDateTime
                SiteCollection   = $rootSite.siteCollection
                Root             = $rootSite.root
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

    $requestParams = @{
        Uri      = $requestUri
        Method   = 'GET'
        Config   = $Config
        AllPages = $AllPages.IsPresent
    }

    $sites = Invoke-ToolkitGraphRequest @requestParams

    foreach ($s in $sites) {
        [PSCustomObject]@{
            Id               = $s.id
            DisplayName      = $s.displayName
            Name             = $s.name
            WebUrl           = $s.webUrl
            CreatedDateTime  = $s.createdDateTime
            LastModifiedTime = $s.lastModifiedDateTime
            SiteCollection   = $s.siteCollection
            Root             = $s.root
        }
    }
}