# exchange

Exchange Online and Purview compliance scripts: mailbox auditing, forwarding/inbox-rule
detection, shared mailbox delegate permission reporting, transport rule inventory, and a
guardrailed compliance search + purge workflow for removing malicious mail tenant-wide.

All scripts take a mandatory `-TenantName` parameter, dot-source `..\core\Common.ps1`,
`..\core\Retry.ps1`, and `..\core\ErrorHandling.ps1`, and connect via
`..\core\Connect-M365.ps1` (`-ConnectExchange` and, for `Purge-Email.ps1`,
`-ConnectPurview`), which resolves tenant details from `config\tenants.json`. No script
hardcodes a tenant ID, domain, or UPN — examples below use the `contoso.com` /
`Tenant-Example-NA` placeholders from `config\tenants.json`.

---

## Prerequisites

- PowerShell 7+ recommended.
- `ExchangeOnlineManagement` module, minimum version 3.9.0 (auto-installed by
  `Ensure-ModuleInstalled` if missing and `ModuleAutoInstall` is enabled).
- An Exchange Online administrator role (View-Only Recipients / Recipient Management or
  higher) for the reporting scripts.
- For `Purge-Email.ps1`: a **Security & Compliance Center** role — **eDiscovery Manager**
  or **eDiscovery Administrator**. Global Admin alone is often *not* sufficient for
  compliance search/purge actions; this trips people up the first time.

---

## Scripts

### Audit-Mailboxes.ps1

Exports AuditEnabled, LitigationHoldEnabled, RetentionPolicy, and WhenCreated for all
mailboxes (or a filtered/shared-only subset). Lists mailboxes with `Get-EXOMailbox
-ResultSize Unlimited`, then pulls per-mailbox detail with a second `Get-EXOMailbox
-Properties` call.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `MailboxFilter` | Wildcard filter against PrimarySmtpAddress or DisplayName. Default `*`. |
| `SharedOnly` | Restrict to shared mailboxes only. |
| `OutputCsv` | Default `.\reports\MailboxAudit.csv`. |

**Configuration block:** `$DetailProperties` (properties requested on the per-mailbox
detail lookup).

**Example**
```powershell
.\Audit-Mailboxes.ps1 -TenantName Tenant-Example-NA -SharedOnly -OutputCsv .\reports\Contoso-SharedAudit.csv
```

---

### Purge-Email.ps1 — guardrailed compliance search + purge

The script for "get this phishing email out of every inbox." Wraps the modern, supported
`New-ComplianceSearch` / `New-ComplianceSearchAction -Purge` workflow (not the deprecated
`Search-Mailbox -DeleteContent`).

**Safety model — verified during this audit:**
- Requires an explicit, non-empty mailbox scope (`-TargetMailbox`/`-TargetMailboxes`); an
  org-wide/unbounded search is not supported.
- Requires at least one narrowing filter (`-SenderAddress`, `-Subject`, `-MessageId`, or
  `-StartDate`/`-EndDate`) — a bare/empty query is rejected before a search is even built.
- Always runs the search/estimate phase first and logs the item count and affected
  mailboxes. **Nothing is deleted during `-Mode Search` (the default).**
- The destructive purge only runs if **all** of the following are true: `-Mode Purge`,
  the explicit `-Confirmed` switch, and `[CmdletBinding(SupportsShouldProcess)]`
  confirmation (`$PSCmdlet.ShouldProcess`) — so `-WhatIf`/`-Confirm` are also honored.
- `PurgeType` defaults to `SoftDelete` (recoverable); `HardDelete` must be explicitly
  requested and is not reversible.
- The whole flow is wrapped in `Invoke-ToolboxSafely`/`Invoke-WithRetry`, and the search
  status poll loop has a hard attempt cap so it can't hang forever.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `TargetMailbox` / `TargetMailboxes` | At least one required. Single or multiple SMTP addresses. |
| `SenderAddress` / `Subject` / `MessageId` / `StartDate` / `EndDate` | At least one required — narrows the search. |
| `SearchQuery` | Optional raw KQL fragment ANDed with the filters above; cannot bypass the mandatory-filter rule by itself. |
| `Mode` | `Search` (default, preview only) or `Purge`. |
| `Confirmed` | Required in addition to `-Mode Purge` for deletion to execute. |
| `PurgeType` | `SoftDelete` (default) or `HardDelete`. |

**Configuration block:** `$SearchPollSeconds` (10), `$MaxSearchPollAttempts` (90).

**Example**
```powershell
# Step 1: preview only, nothing deleted
.\Purge-Email.ps1 -TenantName Tenant-Example-NA -TargetMailbox user@contoso.com `
    -SenderAddress phish@evil-example.com -Subject "Invoice overdue"

# Step 2: purge, once scope looks right
.\Purge-Email.ps1 -TenantName Tenant-Example-NA -TargetMailbox user@contoso.com `
    -MessageId "<abc123@evil-example.com>" -Mode Purge -Confirmed -PurgeType SoftDelete
```

**Known gotchas**
- `SoftDelete` lands items in Recoverable Items — reversible within the mailbox's deleted
  item retention window. `HardDelete` is not reversible.
- Large compliance searches can take several minutes; if `$MaxSearchPollAttempts` is
  reached the script aborts client-side, but the search may still be running
  server-side — check with `Get-ComplianceSearch -Identity <name>`.

---

### Report-MailboxForwarding.ps1

Exports mailbox-level forwarding settings (`ForwardingAddress`, `ForwardingSmtpAddress`,
`DeliverToMailboxAndForward`) for every mailbox, and optionally (`-IncludeInboxRules`)
scans each mailbox's inbox rules (`Get-InboxRule`) for rules that forward, redirect, or
forward-as-attachment.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `OutputCsv` | Default `.\reports\MailboxForwarding.csv`. |
| `IncludeInboxRules` | Also scans inbox rules per mailbox (slower — one extra call per mailbox). |

**Example**
```powershell
.\Report-MailboxForwarding.ps1 -TenantName Tenant-Example-NA -IncludeInboxRules -OutputCsv .\reports\Contoso-Forwarding.csv
```

---

### Report-SharedMailboxPermissions.ps1

Enumerates all shared mailboxes and exports FullAccess delegate permissions
(`Get-MailboxPermission`) and, optionally, Send As permissions
(`Get-RecipientPermission`). Built-in/system entries (`NT AUTHORITY*`, SID-only trustees)
and inherited permissions are filtered out by default.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `OutputCsv` | Default `.\reports\SharedMailboxPermissions.csv`. |
| `IncludeSendAs` | Also reports Send As permissions. |
| `IncludeDefaultEntries` | Includes system/inherited entries normally filtered as noise. |

**Example**
```powershell
.\Report-SharedMailboxPermissions.ps1 -TenantName Tenant-Example-NA -IncludeSendAs -OutputCsv .\reports\Contoso-SharedPerms.csv
```

---

### Report-TransportRules.ps1

Exports every Exchange Online transport (mail flow) rule's name, state, mode, priority,
comments, and description via `Get-TransportRule`.

**Parameters**
| Parameter | Notes |
|---|---|
| `TenantName` | Mandatory. |
| `OutputCsv` | Default `.\reports\TransportRules.csv`. |

**Example**
```powershell
.\Report-TransportRules.ps1 -TenantName Tenant-Example-NA -OutputCsv .\reports\Contoso-TransportRules.csv
```

---

### Audit-SharedMailboxPermissions.ps1

Standalone, self-contained script (not built on `core\Connect-M365.ps1` /
`config\tenants.json` — it manages its own `Connect-ExchangeOnline`/`Connect-MgGraph`
connections and module checks). Audits Full Access, Send As, and Send on Behalf
permissions on every shared mailbox tenant-wide and flags any grant held by an account
that's since been disabled — permission drift left over from offboarding that nobody
cleaned up. Complements `Report-SharedMailboxPermissions.ps1` above: this one is
read-only-by-default and flags *stale* grants specifically, rather than just inventorying
every grant. Unlike `access-profile\Audit-SharedMailboxOU.ps1`, it doesn't depend on a
specific AD OU — it queries Exchange Online directly for every mailbox of type
SharedMailbox tenant-wide.

**Parameters**
| Parameter | Notes |
|---|---|
| `ReportPath` | Folder for the CSV report and transcript log. Default `.\AuditReports`. |
| `AutoInstallMissingModules` | Auto-install missing PSGallery modules instead of prompting. |

**Required modules:** `ExchangeOnlineManagement`, `Microsoft.Graph.Users` (`ActiveDirectory`
used opportunistically if present).

**Example**
```powershell
.\Audit-SharedMailboxPermissions.ps1
```

---

## Related

- `docs\README-Exchange.md` — original short-form reference doc for this folder.
- `docs\Automating-Shared-Mailbox-Cleanup.docx/.pdf` — runbook covering
  `Audit-SharedMailboxPermissions.ps1`.
