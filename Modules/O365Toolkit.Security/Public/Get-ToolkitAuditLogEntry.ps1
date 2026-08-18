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

    Assert-ToolkitGraphConnection
    if (-not $Config) { $Config = @{ Environment = 'Global' } }

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
    $audits = Invoke-ToolkitGraphRequest -Uri $requestUri -Method 'GET' -Config $Config -AllPages:$AllPages.IsPresent

    foreach ($entry in $audits) {
        $initiatorUser = if ($entry.PSObject.Properties['initiatedBy'] -and $entry.initiatedBy -and $entry.initiatedBy.PSObject.Properties['user'] -and $entry.initiatedBy.user) { $entry.initiatedBy.user.userPrincipalName } else { $null }
        $initiatorApp = if ($entry.PSObject.Properties['initiatedBy'] -and $entry.initiatedBy -and $entry.initiatedBy.PSObject.Properties['app'] -and $entry.initiatedBy.app) { $entry.initiatedBy.app.displayName } else { $null }

        [PSCustomObject]@{
            Id                   = if ($entry.PSObject.Properties['id']) { $entry.id } else { $null }
            ActivityDateTime     = if ($entry.PSObject.Properties['activityDateTime']) { $entry.activityDateTime } else { $null }
            ActivityDisplayName  = if ($entry.PSObject.Properties['activityDisplayName']) { $entry.activityDisplayName } else { $null }
            Category             = if ($entry.PSObject.Properties['category']) { $entry.category } else { $null }
            Result               = if ($entry.PSObject.Properties['result']) { $entry.result } else { $null }
            ResultReason         = if ($entry.PSObject.Properties['resultReason']) { $entry.resultReason } else { $null }
            InitiatedByUser      = $initiatorUser
            InitiatedByApp       = $initiatorApp
            TargetResources      = if ($entry.PSObject.Properties['targetResources']) { $entry.targetResources } else { $null }
            AdditionalDetails    = if ($entry.PSObject.Properties['additionalDetails']) { $entry.additionalDetails } else { $null }
        }
    }
}
