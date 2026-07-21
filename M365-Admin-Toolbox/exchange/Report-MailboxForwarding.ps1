<#
.SYNOPSIS
    Reports mailbox forwarding configuration and (optionally) inbox rules that forward or redirect mail.

.DESCRIPTION
    Connects to Exchange Online for the given tenant and exports a CSV listing each mailbox's
    ForwardingAddress/ForwardingSmtpAddress settings, and optionally scans each mailbox's inbox rules for
    any rule that forwards, redirects, or forwards-as-attachment external or internal mail.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json (e.g. Tenant-Example-NA).

.PARAMETER OutputCsv
    Path to write the resulting CSV report. Defaults to .\reports\MailboxForwarding.csv under the toolbox root.

.PARAMETER IncludeInboxRules
    If specified, also scans each mailbox's inbox rules (Get-InboxRule) for forwarding/redirect rules. This
    is slower since it makes one additional call per mailbox.

.EXAMPLE
    .\Report-MailboxForwarding.ps1 -TenantName Tenant-Example-NA -IncludeInboxRules -OutputCsv .\reports\Contoso-Forwarding.csv

    Reports both mailbox-level forwarding settings and inbox-rule-based forwarding/redirects for all
    mailboxes in the Tenant-Example-NA tenant.
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$OutputCsv = '.\reports\MailboxForwarding.csv',
    [switch]$IncludeInboxRules
)

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectExchange

$outputFolder = Split-Path $OutputCsv -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

Invoke-ToolboxSafely -TenantName $TenantName -Operation 'Report-MailboxForwarding' -Rethrow -ScriptBlock {

$mailboxes = Invoke-WithRetry -TenantName $TenantName -Operation 'Get-EXOMailbox-List' -ScriptBlock {
    Get-EXOMailbox -ResultSize Unlimited
}
$rows = foreach ($mb in $mailboxes) {
    $base = [pscustomobject]@{
        TenantName = $TenantName
        Mailbox = $mb.PrimarySmtpAddress
        DisplayName = $mb.DisplayName
        ForwardingAddress = $mb.ForwardingAddress
        ForwardingSmtpAddress = $mb.ForwardingSmtpAddress
        DeliverToMailboxAndForward = $mb.DeliverToMailboxAndForward
        Source = 'MailboxSettings'
        RuleName = ''
        ForwardTo = ''
        RedirectTo = ''
        ForwardAsAttachmentTo = ''
        RuleEnabled = ''
    }
    $base
    if ($IncludeInboxRules) {
        foreach ($rule in (Get-InboxRule -Mailbox $mb.PrimarySmtpAddress -ErrorAction SilentlyContinue)) {
            if ($rule.ForwardTo -or $rule.RedirectTo -or $rule.ForwardAsAttachmentTo) {
                [pscustomobject]@{
                    TenantName = $TenantName
                    Mailbox = $mb.PrimarySmtpAddress
                    DisplayName = $mb.DisplayName
                    ForwardingAddress = ''
                    ForwardingSmtpAddress = ''
                    DeliverToMailboxAndForward = ''
                    Source = 'InboxRule'
                    RuleName = $rule.Name
                    ForwardTo = ($rule.ForwardTo -join ';')
                    RedirectTo = ($rule.RedirectTo -join ';')
                    ForwardAsAttachmentTo = ($rule.ForwardAsAttachmentTo -join ';')
                    RuleEnabled = $rule.Enabled
                }
            }
        }
    }
}
$rows | Export-Csv -NoTypeInformation -Path $OutputCsv
Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Mailbox forwarding report exported to $OutputCsv"
}
