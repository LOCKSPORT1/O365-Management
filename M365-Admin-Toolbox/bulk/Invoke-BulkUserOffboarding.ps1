<#
.SYNOPSIS
    Bulk-offboards M365 users (and optionally their on-prem AD accounts) from a CSV file.

.DESCRIPTION
    Reads a CSV of users and, for each row, invokes ..\lifecycle\Disable-UserLifecycle.ps1 to
    disable the cloud account (convert mailbox to shared, remove licenses, disable devices,
    revoke sessions, etc.). If the row has a SamAccountName AND HybridDisableOnPrem is 'true',
    it also invokes ..\hybrid\Disable-HybridADUser.ps1 to disable the on-prem AD object and then
    ..\hybrid\Start-ADSync.ps1 to trigger a delta sync so the change replicates to the cloud.

    Expected CSV columns (see templates\BulkUserOffboarding.csv):
      TenantName, HybridDisableOnPrem, SamAccountName, UserPrincipalName,
      ConvertMailboxToShared, RemoveLicenses, DisableDevices, RevokeSessions,
      MoveOnPremObjectToDisabledOU, RemoveFromAllNonDefaultGroups

    Boolean-like columns are parsed with ConvertTo-ToolboxBool, which treats a blank/whitespace
    cell as $false instead of throwing, since blank cells are a common CSV data-entry mistake.

    Each row is processed independently in its own try/catch; failures for one row do not stop
    processing of the remaining rows. A per-row summary (Status/Error) is written to a timestamped
    CSV in the ..\reports folder and the path to that report is returned.

.PARAMETER CsvPath
    Path to the input CSV file. See templates\BulkUserOffboarding.csv for the expected format
    and an example row.

.EXAMPLE
    .\Invoke-BulkUserOffboarding.ps1 -CsvPath 'D:\ADMIN SCRIPTS\M365-Admin-Toolbox-v6.2\M365-Admin-Toolbox\templates\BulkUserOffboarding.csv'

    Offboards every user listed in the CSV and writes a summary report to ..\reports.
#>
param(
    [Parameter(Mandatory)][string]$CsvPath
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$script:ReportsFolderRelativePath = '..\reports'
$script:TimestampFormat = 'yyyyMMddHHmmss'

# Parses CSV boolean-like values safely. A blank/whitespace cell (a common CSV data-entry
# mistake) is treated as $false instead of throwing a FormatException like [bool]::Parse does.
function ConvertTo-ToolboxBool {
    param($Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return [bool]::Parse($Value)
}

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
$rows = Import-Csv -Path $CsvPath
$results = foreach ($row in $rows) {
    try {
        & (Join-Path $PSScriptRoot '..\lifecycle\Disable-UserLifecycle.ps1') -TenantName $row.TenantName -UserPrincipalName $row.UserPrincipalName -ConvertMailboxToShared:(ConvertTo-ToolboxBool $row.ConvertMailboxToShared) -RemoveLicenses:(ConvertTo-ToolboxBool $row.RemoveLicenses) -DisableDevices:(ConvertTo-ToolboxBool $row.DisableDevices) -RevokeSessions:(ConvertTo-ToolboxBool $row.RevokeSessions) -MoveOnPremObjectToDisabledOU:(ConvertTo-ToolboxBool $row.MoveOnPremObjectToDisabledOU)
        if ($row.SamAccountName -and $row.HybridDisableOnPrem -eq 'true') {
            & (Join-Path $PSScriptRoot '..\hybrid\Disable-HybridADUser.ps1') -TenantName $row.TenantName -SamAccountName $row.SamAccountName -MoveToDisabledOU:(ConvertTo-ToolboxBool $row.MoveOnPremObjectToDisabledOU) -RemoveFromAllNonDefaultGroups:(ConvertTo-ToolboxBool $row.RemoveFromAllNonDefaultGroups)
            & (Join-Path $PSScriptRoot '..\hybrid\Start-ADSync.ps1') -TenantName $row.TenantName -PolicyType Delta
        }
        [pscustomobject]@{ TenantName=$row.TenantName; UserPrincipalName=$row.UserPrincipalName; Status='Success'; Error='' }
    }
    catch {
        [pscustomobject]@{ TenantName=$row.TenantName; UserPrincipalName=$row.UserPrincipalName; Status='Failed'; Error=$_.Exception.Message }
    }
}
$out = Join-Path (Join-Path $PSScriptRoot $script:ReportsFolderRelativePath) ("BulkUserOffboarding_{0}.csv" -f (Get-Date -Format $script:TimestampFormat))
$results | Export-Csv -NoTypeInformation -Path $out
$out
