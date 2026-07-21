<#
.SYNOPSIS
    Bulk-onboards M365 users (and optionally their on-prem AD accounts) from a CSV file.

.DESCRIPTION
    Reads a CSV of users and, for each row, invokes ..\lifecycle\New-UserLifecycle.ps1 to create
    the cloud account (assign license SKUs and groups, etc.). If BOTH the -HybridCreateOnPremFirst
    switch is passed to this script AND the row's HybridCreateOnPremFirst column is 'true', it
    first invokes ..\hybrid\New-HybridADUser.ps1 to create the on-prem AD object and
    ..\hybrid\Start-ADSync.ps1 to sync it to the cloud before creating/updating the cloud account.
    This dual-gate (script switch AND per-row CSV flag) is intentional: it requires an explicit
    global opt-in for the run plus an explicit per-row opt-in, so hybrid on-prem creation never
    happens by accident.

    Expected CSV columns (see templates\BulkUserOnboarding.csv):
      TenantName, HybridCreateOnPremFirst, SamAccountName, UserPrincipalName, DisplayName,
      GivenName, Surname, MailNickname, Department, JobTitle, OfficeLocation, UsageLocation,
      InitialPassword, LicenseSkuPartNumbers, GroupIds, OnPremGroups
    (LicenseSkuPartNumbers, GroupIds, and OnPremGroups are semicolon-delimited lists.)

    Each row is processed independently in its own try/catch; failures for one row do not stop
    processing of the remaining rows. A per-row summary (Status/TemporaryPassword/Error) is
    written to a timestamped CSV in the ..\reports folder and the path to that report is returned.

    # TODO: TemporaryPassword is written to this CSV in plaintext. Consider redacting it from the
    # summary CSV and instead delivering passwords via a secure channel (e.g. Secrets.ps1 /
    # SecretManagement) for production use.

.PARAMETER CsvPath
    Path to the input CSV file. See templates\BulkUserOnboarding.csv for the expected format
    and example rows.

.PARAMETER HybridCreateOnPremFirst
    Global opt-in switch. Must be passed together with a per-row HybridCreateOnPremFirst='true'
    CSV value for the on-prem AD creation branch to run for that row (see DESCRIPTION).

.EXAMPLE
    .\Invoke-BulkUserOnboarding.ps1 -CsvPath 'D:\ADMIN SCRIPTS\M365-Admin-Toolbox-v6.2\M365-Admin-Toolbox\templates\BulkUserOnboarding.csv' -HybridCreateOnPremFirst

    Onboards every user listed in the CSV, creating on-prem AD accounts first for rows where the
    CSV's HybridCreateOnPremFirst column is 'true', and writes a summary report to ..\reports.
#>
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [switch]$HybridCreateOnPremFirst
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$script:ReportsFolderRelativePath = '..\reports'
$script:TimestampFormat = 'yyyyMMddHHmmss'

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
$rows = Import-Csv -Path $CsvPath
$results = foreach ($row in $rows) {
    try {
        if ($HybridCreateOnPremFirst -and $row.HybridCreateOnPremFirst -eq 'true') {
            & (Join-Path $PSScriptRoot '..\hybrid\New-HybridADUser.ps1') -TenantName $row.TenantName -SamAccountName $row.SamAccountName -UserPrincipalName $row.UserPrincipalName -DisplayName $row.DisplayName -GivenName $row.GivenName -Surname $row.Surname -Department $row.Department -JobTitle $row.JobTitle -OfficeLocation $row.OfficeLocation -InitialPassword $row.InitialPassword -OnPremGroups ($row.OnPremGroups -split ';')
            & (Join-Path $PSScriptRoot '..\hybrid\Start-ADSync.ps1') -TenantName $row.TenantName -PolicyType Delta
        }
        $resp = & (Join-Path $PSScriptRoot '..\lifecycle\New-UserLifecycle.ps1') -TenantName $row.TenantName -DisplayName $row.DisplayName -UserPrincipalName $row.UserPrincipalName -MailNickname $row.MailNickname -GivenName $row.GivenName -Surname $row.Surname -Department $row.Department -JobTitle $row.JobTitle -OfficeLocation $row.OfficeLocation -UsageLocation $row.UsageLocation -LicenseSkuPartNumbers ($row.LicenseSkuPartNumbers -split ';') -GroupIds ($row.GroupIds -split ';')
        [pscustomobject]@{ TenantName=$row.TenantName; UserPrincipalName=$row.UserPrincipalName; Status='Success'; TemporaryPassword=$resp.TemporaryPassword; Error='' }
    }
    catch {
        [pscustomobject]@{ TenantName=$row.TenantName; UserPrincipalName=$row.UserPrincipalName; Status='Failed'; TemporaryPassword=''; Error=$_.Exception.Message }
    }
}
$out = Join-Path (Join-Path $PSScriptRoot $script:ReportsFolderRelativePath) ("BulkUserOnboarding_{0}.csv" -f (Get-Date -Format $script:TimestampFormat))
$results | Export-Csv -NoTypeInformation -Path $out
$out
