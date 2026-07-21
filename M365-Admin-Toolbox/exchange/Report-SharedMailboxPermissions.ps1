<#
.SYNOPSIS
    Reports FullAccess and (optionally) Send As delegate permissions on shared mailboxes.

.DESCRIPTION
    Connects to Exchange Online for the given tenant, enumerates all shared mailboxes, and exports a CSV
    of delegate permissions (Get-MailboxPermission) and optionally Send As permissions
    (Get-RecipientPermission), excluding built-in/inherited default entries (e.g. NT AUTHORITY, SIDs) unless
    -IncludeDefaultEntries is specified.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. Tenant-Example-NA).

.PARAMETER OutputCsv
    Path to write the resulting CSV report. Defaults to .\reports\SharedMailboxPermissions.csv under the
    toolbox root.

.PARAMETER IncludeSendAs
    If specified, also reports Send As permissions in addition to mailbox (FullAccess) permissions.

.PARAMETER IncludeDefaultEntries
    If specified, includes built-in/system entries (NT AUTHORITY*, SID-only trustees) and inherited
    permissions that are normally filtered out as noise.

.EXAMPLE
    .\Report-SharedMailboxPermissions.ps1 -TenantName Tenant-Example-NA -IncludeSendAs -OutputCsv .\reports\Contoso-SharedPerms.csv

    Reports FullAccess and Send As delegate permissions for all shared mailboxes in the Tenant-Example-NA
    tenant, excluding default/system entries.
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$OutputCsv = '.\reports\SharedMailboxPermissions.csv',
    [switch]$IncludeSendAs,
    [switch]$IncludeDefaultEntries
)

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectExchange

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

Invoke-ToolboxSafely -TenantName $TenantName -Operation 'Report-SharedMailboxPermissions' -Rethrow -ScriptBlock {

$mailboxes = Invoke-WithRetry -TenantName $TenantName -Operation 'Get-EXOMailbox-SharedList' -ScriptBlock {
    Get-EXOMailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited
}
$results = foreach ($mb in $mailboxes) {
    $fullAccess = Get-MailboxPermission -Identity $mb.PrimarySmtpAddress | Where-Object {
        $keep = $true
        if ($_.AccessRights -notcontains 'FullAccess') { $keep = $false }
        if (-not $IncludeDefaultEntries) {
            if ($_.User -like 'NT AUTHORITY*' -or $_.User -like 'S-1-*' -or $_.IsInherited) { $keep = $false }
        }
        $keep
    }
    foreach ($perm in $fullAccess) {
        [pscustomobject]@{
            TenantName = $TenantName
            Mailbox = $mb.PrimarySmtpAddress
            Delegate = $perm.User
            PermissionType = 'MailboxPermission'
            AccessRights = ($perm.AccessRights -join ';')
            IsInherited = $perm.IsInherited
            Deny = $perm.Deny
        }
    }
    if ($IncludeSendAs) {
        $sendAs = Get-RecipientPermission -Identity $mb.PrimarySmtpAddress | Where-Object {
            if (-not $IncludeDefaultEntries) { $_.Trustee -notlike 'NT AUTHORITY*' -and $_.Trustee -notlike 'S-1-*' } else { $true }
        }
        foreach ($perm in $sendAs) {
            [pscustomobject]@{
                TenantName = $TenantName
                Mailbox = $mb.PrimarySmtpAddress
                Delegate = $perm.Trustee
                PermissionType = 'SendAs'
                AccessRights = ($perm.AccessRights -join ';')
                IsInherited = $false
                Deny = $false
            }
        }
    }
}
$results | Export-Csv -NoTypeInformation -Path $OutputCsv
Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Shared mailbox permission report exported to $OutputCsv"
}
