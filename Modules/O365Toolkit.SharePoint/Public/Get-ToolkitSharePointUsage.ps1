# Modules/O365Toolkit.SharePoint/Public/Get-ToolkitSharePointUsage.ps1
<#
.SYNOPSIS
    Retrieves storage usage and document metrics for SharePoint sites.
.DESCRIPTION
    Queries the Microsoft Graph drives endpoint for a given SharePoint Site ID to evaluate
    total capacity, storage used, remaining space, and active document drive states.
.PARAMETER SiteId
    The composite ID of the SharePoint site.
.PARAMETER Config
    Optional configuration hashtable containing environment settings.
.OUTPUTS
    [pscustomobject]
.EXAMPLE
    Get-ToolkitSharePointUsage -SiteId 'contoso.sharepoint.com,site-guid-1,web-guid-1'
.NOTES
    Required Microsoft Graph Scopes:
      - Sites.Read.All or Files.Read.All
#>
function Get-ToolkitSharePointUsage {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SiteId,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Config = @{ Environment = 'Global' }
    )

    # ---------------------------------------------------------------------------
    # CHANGE: 2026-08-18 - Initial creation of Get-ToolkitSharePointUsage
    # adhering to Graph API v1.0 path rules (R1.1, R1.2) and locked lexicon (R2.5).
    # Module: O365Toolkit.SharePoint
    # Track: NEUTRAL
    # ---------------------------------------------------------------------------

    Assert-ToolkitGraphConnection

    if (-not $Config) {
        $Config = @{ Environment = 'Global' }
    }

    $relativeUri = "v1.0/sites/$SiteId/drives"
    $requestUri = Get-ToolkitGraphUri -RelativePath $relativeUri -Config $Config

    $requestParams = @{
        Uri    = $requestUri
        Method = 'GET'
        Config = $Config
    }

    $drives = Invoke-ToolkitGraphRequest @requestParams

    foreach ($drive in $drives) {
        $totalBytes = if ($drive.quota.total) { [int64]$drive.quota.total } else { 0 }
        $usedBytes  = if ($drive.quota.used) { [int64]$drive.quota.used } else { 0 }
        $remainingBytes = if ($drive.quota.remaining) { [int64]$drive.quota.remaining } else { 0 }

        $usedMB  = [math]::Round($usedBytes / 1MB, 2)
        $totalMB = [math]::Round($totalBytes / 1MB, 2)
        $percentUsed = if ($totalBytes -gt 0) { [math]::Round(($usedBytes / $totalBytes) * 100, 2) } else { 0 }

        [PSCustomObject]@{
            SiteId         = $SiteId
            DriveId        = $drive.id
            DriveName      = $drive.name
            DriveType      = $drive.driveType
            DriveState     = $drive.quota.state
            UsedMB         = $usedMB
            TotalMB        = $totalMB
            RemainingMB    = [math]::Round($remainingBytes / 1MB, 2)
            PercentUsed    = $percentUsed
            WebUrl         = $drive.webUrl
        }
    }
}