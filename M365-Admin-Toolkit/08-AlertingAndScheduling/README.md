# 08-AlertingAndScheduling

Wires the two highest-priority checks (app registration secret expiry,
mailbox storage) into actual scheduled automation with email/Teams
alerting — instead of CSVs sitting on disk that only get looked at when
someone remembers to run the script.

**Design principle: silent on clean runs.** Every wrapper only sends an
alert when something actually needs attention. Every run — clean or not —
gets logged to a rolling log file, so you have an audit trail without
your inbox getting a "still fine!" email every single day.

**How the four scripts relate:**
- `Send-M365AdminAlert.ps1` is the shared alert-sending helper (email via
  Graph and/or a Teams webhook). It has no scheduled-task role of its own —
  it's dot-sourced by the two wrappers below.
- `Invoke-ScheduledAppSecretExpiryCheck.ps1` and
  `Invoke-ScheduledMailboxStorageCheck.ps1` are the wrappers: each connects
  to M365, calls the matching report script in `07-EnvironmentHealthAutomation`,
  and calls `Send-M365AdminAlert` only if the results need attention.
- `Register-ScheduledTasks.ps1` wires both wrappers into Windows Task
  Scheduler so they run unattended on a recurring basis.

---

## Send-M365AdminAlert.ps1
Shared notification helper. Dot-source it, call `Send-M365AdminAlert`.
Two channels, either or both enabled independently via `$Global:AlertConfig`:

| Setting | Purpose |
|---|---|
| `EmailEnabled` / `EmailFromMailbox` / `EmailToRecipients` / `EmailCcRecipients` | Sent via Graph `Send-MgUserMail` — `EmailFromMailbox` should be a shared mailbox (e.g. `it-alerts@yourdomain.com`), not a personal account |
| `TeamsEnabled` / `TeamsWebhookUrl` | Posts an adaptive card to a webhook URL |

All of these live in a labeled `CONFIGURATION` block near the top of the
file — edit them there for your environment.

### Function parameters
`Send-M365AdminAlert -Subject <string> -Body <string> [-Severity Info|Warning|Critical] [-DetailsUrl <string>]`

| Parameter | Purpose |
|---|---|
| `Subject` | Short subject line — used as email subject (prefixed `[Severity]`) and Teams card title |
| `Body` | Main content — plain text/simple HTML for email, also used as Teams card text |
| `Severity` | `Info` (default), `Warning`, or `Critical` — drives color/styling on both channels |
| `DetailsUrl` | Optional link (e.g. to an exported CSV) added as a clickable action on both channels |

### ⚠️ Teams webhook caveat — read this
Classic Teams "Incoming Webhook" connectors are being retired by
Microsoft in favor of Workflows (Power Automate). Whether that's already
happened for your tenant is worth checking directly rather than assuming —
this has been a moving target and I can't confirm current status without
searching. If Incoming Webhooks still work for you, paste that URL into
`TeamsWebhookUrl` and this script works as-is. If they've been retired,
create a Power Automate flow using the **"When a Teams webhook request is
received"** trigger — it accepts an HTTP POST the same way, so you just
point `TeamsWebhookUrl` at the flow's trigger URL instead; no script
changes needed either way.

### Prerequisites
- `Mail.Send` application permission on the app registration (for email).
- The `EmailFromMailbox` must exist and the app needs rights to send as it.

### Example
```powershell
. .\08-AlertingAndScheduling\Send-M365AdminAlert.ps1
Send-M365AdminAlert -Subject "Mailbox over quota" -Body "5 mailboxes over 90%" -Severity Warning
```

---

## Invoke-ScheduledAppSecretExpiryCheck.ps1
Task Scheduler entry point for the app secret/cert expiry report. Calls
`Assert-M365Connection` (Graph), runs the report from
`07-EnvironmentHealthAutomation\Get-AppRegistrationSecretExpiryReport.ps1`,
exports a timestamped CSV to `Logs\Reports\`, and alerts only if something's
expired (Critical) or expiring within the threshold (Warning).

**Parameter:** `-WarningThresholdDays <int>` (default `30`) — passed straight
through to the underlying report script.

**Config block** (edit near the top of the file):

| Variable | Purpose |
|---|---|
| `ReportScriptPath` | Path to `Get-AppRegistrationSecretExpiryReport.ps1` in `07-EnvironmentHealthAutomation` |
| `ConnectScriptPath` | Path to `00-Setup\Connect-M365Services.ps1` |
| `LogPath` | Rolling log file for every run |
| `ReportExportDir` | Folder for timestamped CSV exports |
| `AuthMode` | `Certificate` by default — unattended runs need Certificate or AppSecret |

### Example
```powershell
# What Task Scheduler runs by default
.\Invoke-ScheduledAppSecretExpiryCheck.ps1

# Run by hand with a tighter threshold to test alerting
.\Invoke-ScheduledAppSecretExpiryCheck.ps1 -WarningThresholdDays 14
```

## Invoke-ScheduledMailboxStorageCheck.ps1
Same pattern for mailbox storage: calls `Assert-M365Connection`
(ExchangeOnline), runs `07-EnvironmentHealthAutomation\Get-MailboxStorageAlert.ps1`,
and alerts (Warning) only on mailboxes over the percent threshold.

**Parameter:** `-WarningPercentThreshold <int>` (default `85`) — passed
straight through to the underlying report script.

**Config block** (edit near the top of the file):

| Variable | Purpose |
|---|---|
| `ReportScriptPath` | Path to `Get-MailboxStorageAlert.ps1` in `07-EnvironmentHealthAutomation` |
| `ConnectScriptPath` | Path to `00-Setup\Connect-M365Services.ps1` |
| `LogPath` | Rolling log file for every run |
| `ReportExportDir` | Folder for timestamped CSV exports |
| `AuthMode` | `Certificate` by default — unattended runs need Certificate or AppSecret |

### Example
```powershell
# What Task Scheduler runs by default
.\Invoke-ScheduledMailboxStorageCheck.ps1

# Run by hand with a looser threshold
.\Invoke-ScheduledMailboxStorageCheck.ps1 -WarningPercentThreshold 90
```

Both wrappers:
- Use `Assert-M365Connection` (not a raw `Connect-M365`) so they play by
  the same "connect only if needed" convention as every other script in
  the toolkit.
- Use **Certificate** auth by default (`$Config.AuthMode`) since these run
  unattended — Interactive auth will hang waiting for a sign-in prompt
  that never comes on a scheduled task.
- Log every run to `Logs\<CheckName>.log`, alert or not.
- Send a Critical alert of their own if the check itself fails to run
  (e.g. auth failure) — so a silent failure doesn't look identical to a
  clean pass.

---

## Register-ScheduledTasks.ps1
Registers both checks as Windows Scheduled Tasks running under `pwsh.exe`.
Run once, elevated, on whichever host runs your other scheduled
automation (matches the pattern of your existing DC-hosted scripts).

**Parameters:**

| Parameter | Purpose |
|---|---|
| `-RunAsAccount` | `Domain\username` of the service account the tasks run as (prompts for password) — placeholder default, override for your environment |
| `-PwshPath` | Path to `pwsh.exe` (PowerShell 7) on the host running the tasks |

**Config block** (`$Tasks` array, edit near the top of the file) — one
entry per task, each with:

| Field | Purpose |
|---|---|
| `Name` | Task Scheduler display name |
| `ScriptPath` | Full path to the wrapper script this task runs (points at the two `Invoke-Scheduled*.ps1` scripts alongside this file) |
| `TriggerTime` | Daily run time, 24h `HH:mm` — configurable here, not hardcoded in the registration logic |
| `Frequency` | Trigger frequency — only `Daily` is currently implemented |

### Usage
```powershell
# Run elevated — registers both tasks with the defaults in $Tasks
.\Register-ScheduledTasks.ps1

# Or specify your service account explicitly
.\Register-ScheduledTasks.ps1 -RunAsAccount "YOURDOMAIN\svc-m365automation"

# Preview without registering anything
.\Register-ScheduledTasks.ps1 -WhatIf
```
Prompts for the service account's password once, then registers both
tasks (App Secret Expiry Check and Mailbox Storage Check) against the
times/frequency defined in the `$Tasks` config block — this is the one
command that sets up ongoing, unattended automation for this folder.

### Known gotchas
- The Graph/EXO app registration used by `Connect-M365Services.ps1` needs
  its cert installed in the **local machine cert store** on whichever host
  runs the scheduled task (not just your admin workstation) — this trips
  people up constantly when a script that worked interactively fails
  under Task Scheduler.
- After registering, **run each task manually once** ("Run" in Task
  Scheduler) before trusting the schedule — confirms auth actually works
  under that service account before waiting a day to find out it doesn't.
- `Mail.Send` and the compliance/Graph scopes are tied to the app
  registration, not the service account — make sure the cert-based auth
  path in `Connect-M365Services.ps1` is fully configured before relying
  on these running unattended.
- Requires admin rights (elevated PowerShell) — `Register-ScheduledTask`
  will fail without them.

### Prerequisites (all four scripts)
- PowerShell 7.x (`pwsh.exe`) on the host running the scheduled tasks.
- `Microsoft.Graph` and `ExchangeOnlineManagement` modules installed (see
  `00-Setup\Connect-M365Services.ps1`).
- `ScheduledTasks` module (built into Windows) for `Register-ScheduledTasks.ps1`.
- Graph `Mail.Send` application permission for the alert email channel.
- `Application.Read.All` (for the app secret check) and standard Exchange
  admin rights (for the mailbox storage check) — see the respective
  scripts in `07-EnvironmentHealthAutomation`.
- Administrator rights on the host to register scheduled tasks.
- A dedicated service account (not a personal admin account) for the
  "Run As" identity on the scheduled tasks.
