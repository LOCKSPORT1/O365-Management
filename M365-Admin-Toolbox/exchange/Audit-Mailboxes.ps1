<#
.SYNOPSIS
    Audits mailboxes in a tenant for audit logging, litigation hold, and retention policy settings.

.DESCRIPTION
    Connects to Exchange Online for the given tenant and exports a CSV report listing each in-scope
    mailbox's AuditEnabled, LitigationHoldEnabled, RetentionPolicy, and WhenCreated values.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. Tenant-Example-NA).

.PARAMETER MailboxFilter
    Wildcard filter applied to PrimarySmtpAddress or DisplayName. Defaults to '*' (all mailboxes).

.PARAMETER SharedOnly
    If specified, restricts the report to shared mailboxes only.

.PARAMETER OutputCsv
    Path to write the resulting CSV report. Defaults to .\reports\MailboxAudit.csv under the toolbox root.

.EXAMPLE
    .\Audit-Mailboxes.ps1 -TenantName Tenant-Example-NA -SharedOnly -OutputCsv .\reports\Contoso-SharedAudit.csv

    Audits only shared mailboxes in the Tenant-Example-NA tenant and writes results to the given CSV path.
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$MailboxFilter = '*',
    [switch]$SharedOnly,
    [string]$OutputCsv = '.\reports\MailboxAudit.csv'
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Properties requested on the detailed per-mailbox lookup
$DetailProperties = 'AuditEnabled', 'LitigationHoldEnabled', 'RetentionPolicy', 'WhenCreated'

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectExchange

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

Invoke-ToolboxSafely -TenantName $TenantName -Operation 'Audit-Mailboxes' -Rethrow -ScriptBlock {
    $mailboxes = Invoke-WithRetry -TenantName $TenantName -Operation 'Get-EXOMailbox-List' -ScriptBlock {
        Get-EXOMailbox -ResultSize Unlimited | Where-Object {
            $_.PrimarySmtpAddress -like $MailboxFilter -or $_.DisplayName -like $MailboxFilter
        }
    }
    if ($SharedOnly) { $mailboxes = $mailboxes | Where-Object { $_.RecipientTypeDetails -eq 'SharedMailbox' } }

    $results = foreach ($mb in $mailboxes) {
        $detail = Invoke-WithRetry -TenantName $TenantName -Operation "Get-EXOMailbox-Detail:$($mb.UserPrincipalName)" -ScriptBlock {
            Get-EXOMailbox -Identity $mb.UserPrincipalName -Properties $DetailProperties
        }
        [pscustomobject]@{
            DisplayName = $detail.DisplayName
            PrimarySmtpAddress = $detail.PrimarySmtpAddress
            RecipientTypeDetails = $detail.RecipientTypeDetails
            AuditEnabled = $detail.AuditEnabled
            LitigationHoldEnabled = $detail.LitigationHoldEnabled
            RetentionPolicy = $detail.RetentionPolicy
            WhenCreated = $detail.WhenCreated
        }
    }
    $results | Export-Csv -NoTypeInformation -Path $OutputCsv
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Mailbox audit exported to $OutputCsv"
}
