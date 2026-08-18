# Modules/O365Toolkit.Security/Public/Get-ToolkitAuditLogEntry.ps1
<#
.SYNOPSIS
    Retrieves directory audit log records from Microsoft Graph.
.DESCRIPTION
    Queries the Microsoft Graph v1.0/auditLogs/directoryAudits endpoint.
    Supports filtering by category, initiatedBy UPN/App, and start/end time windows.
.PARAMETER Category
    The category of directory audit events (e.g., 'UserManagement', 'GroupManagement', 'ApplicationManagement').
.PARAMETER InitiatedBy
    Filter audit events initiated by a specific User Principal Name or Service Principal Name.
.PARAMETER StartTime
    Filter events occurring on or after this timestamp.
.PARAMETER EndTime
    Filter events occurring on or before this timestamp.
.PARAMETER Top
    The maximum number of audit entries to return per page.
.PARAMETER AllPages
    Retrieves all pages of results automatically via @odata.nextLink.
.PARAMETER Config
    Optional configuration hashtable containing environment settings.
.OUTPUTS
    [pscustomobject]
.EXAMPLE
    Get-ToolkitAuditLogEntry -Category 'UserManagement' -Top 50
.EXAMPLE
    Get-ToolkitAuditLogEntry -StartTime (Get-Date).AddDays(-7) -AllPages
.NOTES
    Required Microsoft Graph Scopes:
      - AuditLog.Read.All or Directory.Read.All
#>
function Get-ToolkitAuditLogEntry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Category,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$InitiatedBy,

        [Parameter()]
        [datetime]$StartTime,

        [Parameter()]
        [datetime]$EndTime,

        [Parameter()]
        [ValidateRange(1, 999)]
        [int]$Top,

        [Parameter()]
        [switch]$AllPages,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Config = @{ Environment = 'Global' }
    )

    # ---------------------------------------------------------------------------
    # CHANGE: 2026-08-18 - Initial creation of Get-ToolkitAuditLogEntry
    # adhering to Graph API v1.0 path rules (R1.1, R1.2), connection assertion (R1.6),
    # locked lexicon (R2.5), and fallback config normalization (R2.2).
    # Module: O365Toolkit.Security
    # Track: NEUTRAL
    # ---------------------------------------------------------------------------

    Assert-ToolkitGraphConnection

    if (-not $Config) {
        $Config = @{ Environment = 'Global' }
    }

    $relativeUri = 'v1.0/auditLogs/directoryAudits'
    $queryParams = [System.Collections.Generic.List[string]]::new()
    $filters = [System.Collections.Generic.List[string]]::new()

    if ($Category) {
        $escapedCategory = $Category.Replace("'", "''")
        $filters.Add("category eq '$escapedCategory'")
    }

    if ($InitiatedBy) {
        $escapedInitiator = $InitiatedBy.Replace("'", "''")
        $filters.Add("initiatedBy/user/userPrincipalName eq '$escapedInitiator' or initiatedBy/app/displayName eq '$escapedInitiator'")
    }

    if ($PSBoundParameters.ContainsKey('StartTime') -and $StartTime -ne [datetime]::MinValue) {
        $startUtc = $StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $filters.Add("activityDateTime ge $startUtc")
    }

    if ($PSBoundParameters.ContainsKey('EndTime') -and $EndTime -ne [datetime]::MinValue) {
        $endUtc = $EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $filters.Add("activityDateTime le $endUtc")
    }

    if ($filters.Count -gt 0) {
        $filterString = [System.Uri]::EscapeDataString(($filters -join ' and '))
        $queryParams.Add("`$filter=$filterString")
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

    $audits = Invoke-ToolkitGraphRequest @requestParams

    foreach ($entry in $audits) {
        $initiatorUser = if ($entry.initiatedBy.user) { $entry.initiatedBy.user.userPrincipalName } else { $null }
        $initiatorApp = if ($entry.initiatedBy.app) { $entry.initiatedBy.app.displayName } else { $null }

        [PSCustomObject]@{
            Id                   = $entry.id
            ActivityDateTime     = $entry.activityDateTime
            ActivityDisplayName  = $entry.activityDisplayName
            Category             = $entry.category
            Result               = $entry.result
            ResultReason         = $entry.resultReason
            InitiatedByUser      = $initiatorUser
            InitiatedByApp       = $initiatorApp
            TargetResources      = $entry.targetResources
            AdditionalDetails    = $entry.additionalDetails
        }
    }
}