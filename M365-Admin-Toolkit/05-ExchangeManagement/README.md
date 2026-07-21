# 05-ExchangeManagement

Shared mailbox lifecycle, delegate/permission management, message trace,
and org-wide email purge (phishing/malware remediation).

All scripts self-connect via `00-Setup\Connect-M365Services.ps1`
(`Assert-M365Connection`) and expose `-AuthMode Interactive|AppSecret|Certificate`.
No manual dot-sourcing required.

---

## New-SharedMailbox.ps1

### What it does
Creates a shared mailbox (no license needed under 50GB), sets quota,
optionally enables auto-expanding archive, and grants initial Full
Access / Send As delegates in one pass. Mailbox creation, quota/GAL
configuration, archive enablement, and each delegate grant are individually
wrapped in try/catch so one failure (e.g. a bad UPN in `-FullAccessUsers`)
doesn't silently abort the rest.

### Parameters
| Parameter | Notes |
|---|---|
| `MailboxName` | Display name (mandatory) |
| `PrimarySmtpAddress` | e.g. `billing@yourdomain.com` (mandatory) |
| `FullAccessUsers` / `SendAsUsers` | Arrays of UPNs to delegate immediately |
| `AutoMapping` | `[bool]`, whether the mailbox auto-adds to delegates' Outlook (default `$true`; pass `-AutoMapping:$false` to disable) |
| `EnableAutoExpandingArchive` | For high-volume shared inboxes |
| `ProvisioningWaitSeconds` | Delay after mailbox creation before setting further properties (default 15) |
| `AuthMode` | `Interactive` (default) / `AppSecret` / `Certificate` |

### Configuration block (`$Config`, top of script)
| Variable | Purpose |
|---|---|
| `DefaultProhibitSendReceiveQuotaGB` | Set to 49 by default to stay under the 50GB license-free threshold |
| `HideFromGAL` | Whether the mailbox is hidden from the address list |

### Prerequisites
- Exchange Online session (`Assert-M365Connection -Services ExchangeOnline`).
- Role: **Recipient Management** (or Exchange Admin) in Exchange Online / Entra ID.

### Usage
```powershell
.\New-SharedMailbox.ps1 -MailboxName "Accounts Receivable" -PrimarySmtpAddress "billing@yourdomain.com" `
    -FullAccessUsers "jane.doe@yourdomain.com","john.smith@yourdomain.com" `
    -SendAsUsers "jane.doe@yourdomain.com"
```

---

## Manage-SharedMailboxPermissions.ps1

### What it does
Add, remove, or **audit** Full Access / Send As / Send on Behalf on any
mailbox. `Audit` is the one you'll use most — "who has access to X?" with
no downside risk. Add/Remove operations are wrapped in try/catch so a bad
identity or permission conflict reports a clear error instead of a raw
cmdlet exception.

### Parameters
| Parameter | Notes |
|---|---|
| `MailboxIdentity` | Mailbox to inspect/modify (mandatory) |
| `Action` | `Add` / `Remove` / `Audit` (mandatory) |
| `PermissionType` | `FullAccess` / `SendAs` / `SendOnBehalf` — required for Add/Remove |
| `TargetUser` | UPN of the delegate — required for Add/Remove |
| `AutoMapping` | `[bool]`, applies to `FullAccess` grants only (default `$true`; pass `-AutoMapping:$false` to disable) |
| `AuthMode` | `Interactive` (default) / `AppSecret` / `Certificate` |

### Prerequisites
- Exchange Online session (`Assert-M365Connection -Services ExchangeOnline`).
- Role: **Recipient Management** (or Exchange Admin) to grant/revoke permissions;
  read-only roles are sufficient for `-Action Audit`.

### Usage
```powershell
# Who has access?
.\Manage-SharedMailboxPermissions.ps1 -MailboxIdentity "billing@yourdomain.com" -Action Audit

# Grant
.\Manage-SharedMailboxPermissions.ps1 -MailboxIdentity "billing@yourdomain.com" -Action Add -PermissionType FullAccess -TargetUser "new.hire@yourdomain.com"

# Revoke
.\Manage-SharedMailboxPermissions.ps1 -MailboxIdentity "billing@yourdomain.com" -Action Remove -PermissionType SendAs -TargetUser "former.employee@yourdomain.com"
```

---

## Get-MessageTraceReport.ps1

### What it does
Runs a message trace over a date range with optional sender/recipient/
subject/status filters. Automatically detects if your range goes back
further than the configured threshold (10 days by default) and switches
to the async historical search API (`Start-HistoricalSearch`) instead of
failing silently with an empty result. `Get-MessageTrace`,
`Export-Csv`, and `Start-HistoricalSearch` are each wrapped in try/catch.

### Parameters
| Parameter | Notes |
|---|---|
| `StartDate` / `EndDate` | Defaults to last 2 days |
| `SenderAddress` / `RecipientAddress` / `Subject` / `Status` | Optional filters |
| `ExportPath` | CSV output (recent-window searches only — see gotcha below) |
| `HistoricalPollIntervalSeconds` / `HistoricalMaxWaitMinutes` | Polling behavior for the >threshold-day path |
| `HistoricalSearchThresholdDays` | Cutoff (days) that decides recent vs. historical path (default 10) |
| `AuthMode` | `Interactive` (default) / `AppSecret` / `Certificate` |

### Configuration block (top of script)
| Variable | Default | Purpose |
|---|---|---|
| `StartDate` (when not passed) | Now - 2 days | Default lookback window |
| `ExportPath` (when not passed) | `.\MessageTrace_<timestamp>.csv` | CSV output path/name |
| `HistoricalPollIntervalSeconds` | 60 | Poll frequency for historical search |
| `HistoricalMaxWaitMinutes` | 20 | Ceiling to wait on a historical search |
| `HistoricalSearchThresholdDays` | 10 | Age at which the script switches to the historical search API |

### Prerequisites
- Exchange Online session (`Assert-M365Connection -Services ExchangeOnline`).
- Role: **View-Only Recipients** / Global Reader is generally sufficient for
  message trace; no destructive permissions required.

### Usage
```powershell
# Recent — direct CSV export
.\Get-MessageTraceReport.ps1 -SenderAddress "suspicious@external-domain.com" -StartDate (Get-Date).AddDays(-3)

# Older than the threshold — async historical search
.\Get-MessageTraceReport.ps1 -SenderAddress "suspicious@external-domain.com" -StartDate (Get-Date).AddDays(-30)
```

### Known gotchas
- Historical search results come back as a **download link**, not a local
  CSV — the script prints the URL but can't fetch it directly (Microsoft
  serves it through an authenticated portal link, not a plain HTTP GET).
- Message trace data typically only goes back 90 days on standard plans
  (longer with certain retention/compliance add-ons).

---

## Invoke-EmailPurge.ps1 — the "get this phishing email out of every inbox" script

### What it does
This is the one you're probably after for "purge bad emails." It wraps
the **modern, supported** compliance search + purge workflow
(`New-ComplianceSearch` / `New-ComplianceSearchAction -Purge`) — this
replaces the old `Search-Mailbox -DeleteContent` cmdlet, which Microsoft
has deprecated and retired in most tenants.

**Multiple layered safety gates, intentionally:**
1. **Search-first, always.** The script refuses to run an unbounded
   org-wide query — at least one of `-SenderAddress`, `-Subject`, or
   `-MessageId` is required. A compliance search must exist and reach
   `Completed` status (showing item count and matched mailboxes) before
   any purge can be considered.
2. `-Mode Preview` — runs the search only. Shows item count and which
   mailboxes matched. **Deletes nothing.**
3. `-Mode Purge -Confirmed` — reuses that same named search and submits
   the actual purge. Won't run without `-Confirmed`.
4. **Standard PowerShell `-WhatIf` / `-Confirm` support** (`SupportsShouldProcess`,
   `ConfirmImpact = High`) sits on top of `-Confirmed` as a second,
   independent gate — run with `-WhatIf` to see exactly what would be
   purged without submitting anything, or omit `-Confirmed`/answer "no"
   at the `-Confirm` prompt to abort.
5. Every search and purge action (query, item counts, purge type, status)
   is appended to a text log (`-LogPath`, defaults to `.\EmailPurge_Log.txt`)
   for audit trail purposes.
6. Search creation, and purge submission are wrapped in try/catch so a
   Compliance Center error surfaces cleanly instead of continuing with a
   half-finished operation.

### Parameters
| Parameter | Notes |
|---|---|
| `Mode` | `Preview` or `Purge` — mandatory |
| `SearchName` | Auto-generated if omitted; reuse the same name to go from Preview → Purge without re-searching |
| `SenderAddress` / `Subject` / `MessageId` | At least one required — script refuses to build an unbounded org-wide query |
| `ReceivedAfter` / `ReceivedBefore` | Narrow the date window |
| `PurgeType` | `SoftDelete` (default, recoverable) or `HardDelete` (permanent — flagged with a warning at run time) |
| `Confirmed` | Required safety gate for `-Mode Purge`, in addition to `-WhatIf`/`-Confirm` |
| `PollIntervalSeconds` | Compliance search / purge action poll frequency (default 20s) |
| `MaxWaitMinutes` | Ceiling to wait on search/purge before giving up polling (default 10; job keeps running server-side) |
| `LogPath` | Text log of searches/purges taken (default `.\EmailPurge_Log.txt`) |
| `AuthMode` | `Interactive` (default) / `AppSecret` / `Certificate` |

### Configuration block (top of script, after `param()`)
`PurgeType`, `PollIntervalSeconds`, `MaxWaitMinutes`, and `LogPath` all have
their defaults set in a labeled CONFIGURATION block so environment-specific
tuning lives in one place near the top of the file.

### Prerequisites
- Connect the Compliance Center session, not just Graph/EXO:
  ```powershell
  Connect-M365 -Services ComplianceCenter
  ```
- The account/app needs the **eDiscovery Manager** (or eDiscovery
  Administrator) role in the Security & Compliance Center — specifically,
  the ability to perform **Search and Purge** actions. Global Admin
  alone is often **not** sufficient for compliance search actions —
  this trips people up the first time. Confirm the role assignment at
  Microsoft Purview compliance portal → Permissions → Roles, under the
  eDiscovery Manager role group's "Search and Purge" role.

### Usage — safe end-to-end example
```powershell
# Step 1: search/estimate only. Nothing is deleted. Review the item count
# and matched mailboxes printed at the end before proceeding.
.\Invoke-EmailPurge.ps1 -Mode Preview -SenderAddress "phish@bad-domain.com" -Subject "Invoice overdue" -ReceivedAfter (Get-Date).AddDays(-3)

# Step 2 (optional): dry-run the purge itself with -WhatIf to see exactly
# what ShouldProcess would do, without -Confirmed even being evaluated.
.\Invoke-EmailPurge.ps1 -Mode Purge -SearchName "Purge_20260630_143000" -Confirmed -WhatIf

# Step 3: once scope looks right, purge for real using the same search name.
# Both -Confirmed and the interactive -Confirm prompt (ConfirmImpact=High)
# must be satisfied.
.\Invoke-EmailPurge.ps1 -Mode Purge -SearchName "Purge_20260630_143000" -Confirmed
```

### Known gotchas
- `SoftDelete` lands items in Recoverable Items per mailbox — recoverable
  within that mailbox's deleted-item retention window if you need to
  reverse it. `HardDelete` is not reversible — use `SoftDelete` unless
  you're certain. The script prints a warning when `HardDelete` is used.
- Compliance search across a large tenant can take several minutes to
  complete — the script polls but has a `MaxWaitMinutes` ceiling; if it
  times out, the search keeps running server-side and you can check
  `Get-ComplianceSearch -Identity <name>` manually.
- This searches primary mailboxes + archives it's scoped to via
  `-ExchangeLocation All`. It does not reach into public folders or
  Teams/SharePoint — that requires broadening the eDiscovery scope,
  which this script doesn't currently do.
- Check `-LogPath` (default `.\EmailPurge_Log.txt`) after any run for a
  timestamped audit trail of what was searched and purged.
