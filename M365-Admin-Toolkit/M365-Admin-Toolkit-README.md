# M365 Admin Toolkit — User & Device Lifecycle Automation

A PowerShell script library for Microsoft 365 / Entra ID administration,
covering the full lifecycle: onboarding, licensing, device enrollment,
offboarding, and ongoing reporting/reconciliation. Built for a hybrid
AD/Entra ID environment synced via Entra Connect, using the modern
Microsoft Graph PowerShell SDK and ExchangeOnlineManagement module (not
the deprecated MSOnline/AzureAD modules).

## Folder structure
```
00-Setup/                    Connect-M365Services.ps1 — auth helper, dot-source this first
01-Onboarding/                New user creation + license/group assignment
02-Offboarding/               Full user offboarding pipeline
03-DeviceLifecycle/            Intune inventory, retire/wipe, Autopilot enrollment
04-Reporting-Reconciliation/  License waste + inactive account audits
05-ExchangeManagement/         Shared mailboxes, permissions, message trace, email purge
06-HybridDynamicGroupBridge/    Bridge local AD group membership into cloud-only dynamic groups
07-EnvironmentHealthAutomation/ App secret expiry, guest review, mailbox storage, ownerless groups, MFA gaps, stale devices, bulk CSV onboarding
08-AlertingAndScheduling/       Email/Teams alerting + Windows Scheduled Task registration for the priority checks
```

Every script folder has its own `README.md` with: what the script does,
every predefined/configurable variable, prerequisites, usage examples, and
known gotchas.

## Tenant-agnostic by design
Every value that's specific to an organization — domain names, AD server/OU
paths, group names, department mappings, email recipients — has been
reduced to an obvious placeholder (`yourdomain.com`, `dc01.yourdomain.local`,
`OU=Users,DC=yourdomain,DC=local`, `YOURDOMAIN\svc-account`, etc.). Nothing
in this toolkit is hardcoded to a specific company. Every placeholder is
called out in the corresponding module's README so you know exactly what
to edit before running anything for real.

## Every script connects itself - no manual dot-sourcing required
Every script that talks to Graph, Exchange Online, or the Security &
Compliance Center checks whether a session is already live and connects
automatically if not, right at the top before any other logic runs. You
don't need to separately dot-source `Connect-M365Services.ps1` and call
`Connect-M365` yourself before running something else in this toolkit -
each script is self-sufficient and can be run standalone.

This is controlled by a shared `Assert-M365Connection` function (defined in
`00-Setup\Connect-M365Services.ps1`) that every other script calls with the
service(s) it needs. Every script exposes an `-AuthMode` parameter
(`Interactive`, `AppSecret`, or `Certificate`) so you control how it
authenticates:
```powershell
# Ad-hoc, MFA-friendly - prompts for sign-in if not already connected
.\Get-IntuneDeviceInventory.ps1

# Unattended / scheduled - uses the cert configured in Connect-M365Services.ps1
.\Get-IntuneDeviceInventory.ps1 -AuthMode Certificate
```
If you're already connected from a previous script in the same PowerShell
session, re-running another script skips reconnecting entirely — you'll
see `[Connection check] Already connected: ...` instead of a new sign-in
prompt.

## Getting started
1. Install required modules:
   ```powershell
   Install-Module Microsoft.Graph -Scope CurrentUser
   Install-Module ExchangeOnlineManagement -Scope CurrentUser
   ```
2. Use **PowerShell 7** (`pwsh.exe`) — not 5.1. EXO session handling on 5.1
   is markedly less reliable, especially in loops.
3. Edit `00-Setup/Connect-M365Services.ps1` — fill in your TenantId and
   OrganizationDomain (the verified `*.onmicrosoft.com` name, required by
   Exchange Online/Compliance Center app-only auth), and either your app
   registration ClientId/CertThumbprint (for unattended runs) or just use
   Interactive mode for hands-on admin work.
4. Every other script's `#region Configuration` block at the top has
   tenant-specific values (OU paths, DC/server names, SKU part numbers,
   group names) that **will not work as-is** — they're placeholders
   matching common naming conventions. Edit them to match your tenant
   before running anything for real.
5. Run everything with `-WhatIf` first where supported, and test against
   a non-production/test account before wiring into scheduled automation.

## Design principles used throughout
- **Config blocks up top, logic below.** Every script separates "things
  you need to edit for your tenant" from the actual logic, clearly marked
  `#region Configuration - EDIT THESE VARIABLES`.
- **Fail loud, but don't die halfway.** Multi-step scripts (offboarding
  especially) wrap each step in try/catch and report a summary at the end
  rather than stopping on the first error and leaving things half-done.
- **Destructive actions require explicit confirmation.** Device wipe/retire
  won't run without an explicit `-Confirmed` flag, on top of standard
  `-WhatIf`/`-Confirm` support.
- **Graph SDK + EXO, not legacy modules.** MSOnline and AzureAD modules are
  deprecated/retired — everything here targets Microsoft.Graph and
  ExchangeOnlineManagement.

## Ideas for extending the toolkit
- Wire `04-Reporting-Reconciliation` scripts into a scheduled task on an
  automation host and pipe output somewhere it will actually be seen
  (email, Teams webhook, or an RMM custom field/alert).
- If your RMM platform supports custom fields, consider adding a "last
  offboarded date" or "lifecycle stage" field that `02-Offboarding` and
  `03-DeviceLifecycle` scripts update on completion — a single pane of
  glass without building a separate dashboard.
- The Autopilot script assumes you already have hardware hashes in hand;
  if new-device intake is a recurring pain point, a natural next addition
  is a script that notifies you when a device lands in the imported
  Autopilot table but never completes profile assignment (stuck in limbo).

## What's intentionally NOT automated here
- Hard deletion of user/device objects — kept manual/deliberate pending
  retention windows and sign-off.
- AnyDesk, CrowdStrike sensor removal, FileCloud account cleanup — not
  Graph/EXO-scriptable in a standard way; keep these on a manual checklist
  or build them out as a separate NinjaRMM-triggered script pass.
