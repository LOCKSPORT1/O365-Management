# 07-EnvironmentHealthAutomation

Seven scripts targeting the automation gaps that consistently show up
across cloud-only, hybrid, and on-prem-adjacent M365 environments — the
"little things" that don't feel urgent until they cause an outage or an
audit finding. Meant to run on a recurring schedule (weekly/monthly),
not just once.

All seven read-only report scripts self-connect via the shared
`Assert-M365Connection` helper (`00-Setup\Connect-M365Services.ps1`) and
expose an `-AuthMode` parameter (`Interactive`, `AppSecret`, or
`Certificate`) so they work standalone, double-clicked, or on a scheduled
task. Every script wraps its Graph/EXO calls in try/catch so a single
transient API failure produces a clear warning/error instead of an
unhandled exception. Two scripts in this folder are **not** purely
read-only — see the callouts below for
`Get-StaleEntraDeviceCleanup.ps1` and `New-BulkUserImportFromCsv.ps1`.

**A note on sourcing:** this module was built from well-established
admin-community consensus (repeated patterns across Tech Community,
sysadmin forums, MS documentation) rather than a live web search — no
search tool was active for this pass. Nothing here is exotic; these are
the recurring "wish I'd automated this sooner" categories.

## Prerequisites (all scripts)
- PowerShell 7.x recommended (see `00-Setup\Connect-M365Services.ps1` notes).
- Modules: `Microsoft.Graph`, `ExchangeOnlineManagement` (only
  `Get-MailboxStorageAlert.ps1` needs EXO; the rest use Graph only).
- Fill in tenant-specific values (`TenantId`, `OrganizationDomain`,
  `ClientId`, `CertThumbprint`/`ClientSecret`) in
  `00-Setup\Connect-M365Services.ps1` before using `AppSecret` or
  `Certificate` auth modes.

---

## Get-AppRegistrationSecretExpiryReport.ps1
**Why it matters most:** probably the highest-value script in this
module. An app registration's client secret or certificate expiring
silently is one of the most common causes of "this integration just
stopped working and nobody knows why" — Power Automate flows, scheduled
scripts, SSO integrations, anything using app-only auth.

Walks every app registration tenant-wide (`Get-MgApplication`), checks
both `passwordCredentials` (secrets) and `keyCredentials` (certs), and
flags anything expired or expiring within `WarningThresholdDays`.

**Config / parameters:** `-WarningThresholdDays` (default 30),
`-ExportPath` (default `.\AppRegSecretExpiry_<date>.csv`), `-AuthMode`.

**Graph scope:** `Application.Read.All`.
```powershell
.\Get-AppRegistrationSecretExpiryReport.ps1 -WarningThresholdDays 45
.\Get-AppRegistrationSecretExpiryReport.ps1 -AuthMode Certificate -ExportPath "C:\Reports\AppRegExpiry.csv"
```

---

## Get-GuestUserAccessReview.ps1
Guest (B2B) accounts added for one project and never removed are a
standing, usually-forgotten access footprint. Pulls all guests
(`Get-MgUser -Filter "userType eq 'Guest'"`), their last sign-in
(`SignInActivity`), and group/Teams memberships (`Get-MgUserMemberOf`),
and flags anyone with no sign-in (or none within `StaleThresholdDays`) as
a removal candidate for a periodic access review.

**Config / parameters:** `-StaleThresholdDays` (default 90),
`-ExportPath` (default `.\GuestAccessReview_<date>.csv`), `-AuthMode`.

**Graph scopes:** `User.Read.All`, `AuditLog.Read.All` (`signInActivity`
requires Entra ID P1/P2 licensing).
```powershell
.\Get-GuestUserAccessReview.ps1 -StaleThresholdDays 90
.\Get-GuestUserAccessReview.ps1 -StaleThresholdDays 60 -AuthMode Certificate
```

---

## Get-MailboxStorageAlert.ps1
Catches near-full mailboxes before they turn into "why can't I send
email" tickets. Loops `Get-Mailbox` / `Get-MailboxStatistics` for every
user mailbox, calculates percent-of-quota used, and flags anything at or
above `WarningPercentThreshold`. `-IncludeArchive` adds archive mailbox
size to the output for context (it does not factor into the percentage
calculation, which is primary mailbox only).

**Config / parameters:** `-WarningPercentThreshold` (default 85),
`-IncludeArchive` (switch), `-ExportPath` (default
`.\MailboxStorageReport_<date>.csv`), `-AuthMode`.

**Requires:** Exchange Online connection (auto-connects via
`Assert-M365Connection -Services ExchangeOnline`); no Graph scope needed.
```powershell
.\Get-MailboxStorageAlert.ps1 -WarningPercentThreshold 80 -IncludeArchive
```
**Gotcha:** loops `Get-MailboxStatistics` per mailbox — expect a slow run
on large tenants. A per-mailbox failure is caught and skipped (logged as
a warning) rather than aborting the whole run.

---

## Get-OwnerlessGroupsReport.ps1
Finds M365 Groups/Teams/Distribution Groups with zero owners — usually
the result of the creator leaving and ownership never being reassigned
during offboarding. Pulls all groups (`Get-MgGroup`), checks
`Get-MgGroupOwner` per group, and reports any group with an owner count
of zero along with member count and group type.

**Config / parameters:** `-ExportPath` (default
`.\OwnerlessGroups_<date>.csv`), `-AuthMode`.

**Graph scope:** `Group.Read.All`.
```powershell
.\Get-OwnerlessGroupsReport.ps1
.\Get-OwnerlessGroupsReport.ps1 -ExportPath "C:\Reports\OwnerlessGroups.csv" -AuthMode Certificate
```
**Tie-in:** worth cross-referencing against `02-Offboarding` — consider
adding an ownership-reassignment step there for anyone who owns groups.

---

## Get-MFARegistrationComplianceReport.ps1
Flags accounts with no MFA registered at all, and separately flags
accounts registered only with a weak method (SMS/voice vs. Authenticator/
FIDO2/Windows Hello/OTP token). Conditional Access policies can't protect
what isn't registered — this is the report that tells you where the
actual coverage gaps are versus what policy documents claim.

Pulls the tenant-wide rollup via
`Get-MgReportAuthenticationMethodUserRegistrationDetail` (a single report
call instead of looping every user). By default, disabled/blocked-sign-in
accounts are excluded from the report since the endpoint itself doesn't
expose enabled/disabled state — excluding them requires an extra
`Get-MgUser` lookup to cross-reference `AccountEnabled`; pass
`-IncludeDisabledAccounts` to skip that filtering and see everyone.

**Config / parameters:** `-IncludeDisabledAccounts` (switch, off by
default), `-ExportPath` (default `.\MFAComplianceReport_<date>.csv`),
`-AuthMode`.

**Graph scopes:** `Reports.Read.All` (and/or
`UserAuthenticationMethod.Read.All` as a per-user fallback); also
`User.Read.All` when the default disabled-account filtering is active.
```powershell
.\Get-MFARegistrationComplianceReport.ps1
.\Get-MFARegistrationComplianceReport.ps1 -IncludeDisabledAccounts -AuthMode AppSecret
```

---

## Get-StaleEntraDeviceCleanup.ps1 — takes action, not read-only
Broader than the Intune-specific device inventory in `03-DeviceLifecycle`
— this covers **every** Entra device object (hybrid-joined, Entra-joined,
personally registered), including ones that never enrolled in Intune.
Stale duplicate objects from re-imaging, decommissioned machines never
formally removed, one-time personal device registrations — each one is
still evaluated by Conditional Access and device-based dynamic groups.

**Safety model:** defaults to `-Action ReportOnly` (no changes, ever,
unless you explicitly ask). `Disable` and `Delete` additionally require
`-Confirmed` — without it the script errors out before making any
change, so a mistyped or scheduled run can never take destructive action
unattended. The script also implements `SupportsShouldProcess`, so
`-WhatIf` works against `Disable`/`Delete` to preview exactly which
devices would be touched, and `-Confirm` prompts per device. Each
device's disable/delete call is individually wrapped in try/catch, so one
failure doesn't stop the rest of the batch — failures are listed at the
end.

**Config / parameters:** `-StaleThresholdDays` (default 180), `-Action`
(`ReportOnly` default / `Disable` / `Delete`), `-Confirmed` (switch,
required for non-report actions), `-ExportPath` (default
`.\StaleDeviceReport_<date>.csv`), `-AuthMode`.

**Graph scopes:** `Device.Read.All` for reporting;
`Device.ReadWrite.All` additionally required for `-Disable`/`-Delete`.
```powershell
# Review first - always report-only unless both -Action and -Confirmed are supplied
.\Get-StaleEntraDeviceCleanup.ps1 -StaleThresholdDays 180

# Preview exactly what would be disabled, no changes made
.\Get-StaleEntraDeviceCleanup.ps1 -Action Disable -Confirmed -WhatIf

# Clean up once reviewed
.\Get-StaleEntraDeviceCleanup.ps1 -StaleThresholdDays 180 -Action Disable -Confirmed
```

---

## New-BulkUserImportFromCsv.ps1 — creates users, not read-only
A thin orchestration wrapper — the "we hired 12 people, here's a
spreadsheet" scenario. Doesn't duplicate onboarding logic; it calls
`01-Onboarding\New-M365UserOnboarding.ps1` once per CSV row and
consolidates the results, including a secure handoff CSV of generated
temp passwords instead of scrolling console output per user.

**Safety model:** validates the CSV exists, is non-empty, and has all
required columns before processing anything. Each row is additionally
checked for blank required fields and processed in its own try/catch —
a malformed or failing row is recorded as a failure and the batch
continues rather than aborting. A `finally` block guarantees the
transcript capture used to scrape the temp password is always stopped
and cleaned up, even if a row's onboarding call throws, so a failure
can't leave a dangling transcript session that breaks the next row. A
final summary table plus failure count is printed and exported.

### CSV format required
```
FirstName,LastName,JobTitle,Department,ManagerUpn
Jane,Doe,Warehouse Associate,Production,john.smith@yourdomain.com
```

**Config / parameters:** `-CsvPath` (mandatory), `-Mode`
(`CloudOnly`/`HybridSync`, default `HybridSync`),
`-CredentialExportPath` (default
`.\BulkOnboarding_Credentials_<timestamp>.csv`). Internal configuration
(`$OnboardingScriptPath`, `$RequiredCsvColumns`) is collected in a
CONFIGURATION block near the top of the script if the relative path to
`01-Onboarding\New-M365UserOnboarding.ps1` ever needs adjusting.

**Prerequisites:** whatever Graph/EXO scopes
`01-Onboarding\New-M365UserOnboarding.ps1` itself requires, since this
script is a wrapper around it and inherits its permission needs.
```powershell
.\New-BulkUserImportFromCsv.ps1 -CsvPath "C:\HR\NewHires.csv" -Mode HybridSync
.\New-BulkUserImportFromCsv.ps1 -CsvPath "C:\HR\NewHires.csv" -Mode CloudOnly -CredentialExportPath "C:\Secure\Handoff.csv"
```
**Gotcha:** parses temp passwords out of the onboarding script's console
output via transcript capture — if you ever change that script's output
wording, update the regex here too. Delete the credential export file
after handoff; don't leave temp passwords sitting in plaintext CSVs.

---

## Suggested schedule
| Script | Suggested frequency |
|---|---|
| App registration secret expiry | Weekly |
| Guest user access review | Monthly |
| Mailbox storage alert | Weekly |
| Ownerless groups | Monthly |
| MFA registration compliance | Monthly, or after any bulk onboarding |
| Stale Entra device cleanup | Quarterly |
| Bulk CSV import | As-needed |
