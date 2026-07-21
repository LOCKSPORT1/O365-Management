# Exchange and Purview scripts

## Purge-Email.ps1
Uses Exchange Online and Purview compliance search/purge operations.

### Workflow
1. Loads the connector with Exchange and Purview switches.
2. Creates a compliance search for the target mailbox.
3. Starts the search and waits for completion.
4. If `-WhatIf` is not used, starts the purge action.

### Parameters
- `TenantName`
- `TargetMailbox`
- `SearchQuery`
- `PurgeType` - `HardDelete` or `SoftDelete`
- `WhatIf`

### Example
```powershell
.\exchange\Purge-Email.ps1 -TenantName Tenant-Example-NA -TargetMailbox user@contoso.com -SearchQuery 'Subject:"Phishing"' -WhatIf
```

## Audit-Mailboxes.ps1
Audits shared or user mailboxes and exports operational settings to CSV.

### Output fields
- DisplayName
- PrimarySmtpAddress
- RecipientTypeDetails
- AuditEnabled
- LitigationHoldEnabled
- RetentionPolicy
- WhenCreated


## Report-SharedMailboxPermissions.ps1
Exports shared mailbox delegate permissions using Exchange Online permission cmdlets. It can include mailbox permissions and optional Send As data.


## Report-TransportRules.ps1
Exports Exchange Online transport rule inventory.

## Report-MailboxForwarding.ps1
Audits mailbox forwarding settings and can optionally enumerate inbox rules that forward or redirect mail.
