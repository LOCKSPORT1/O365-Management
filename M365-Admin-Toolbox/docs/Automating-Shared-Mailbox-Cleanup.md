Automating Shared-Mailbox Cleanup

*Two ways to automate running Audit-SharedMailboxOU (either the tenant-preset or vendor-neutral variant) with -Remediate, so leftover local AD and cloud group memberships get cleaned up without you manually kicking it off every time.*

*Location: Audit-SharedMailboxOU.ps1 lives in your private tenant-preset folder, Audit-SharedMailboxOU.ps1 lives in the Neutral folder. This guide applies to either one equally and lives in the Shared folder alongside the other cross-cutting reference docs.*

1\. The scripts stay interactive — here's what that means for automation

Audit-SharedMailboxOU-\*.ps1 (and the offboarding scripts it shares logic with) sign in to Exchange Online and Microsoft Graph interactively — each run pops a login window and, if needed, an MFA prompt. That's the right default for a script a person runs at their desk. It also means a task scheduled to run with nobody logged in has no way to complete that sign-in and will simply hang or fail.

There are two honest ways to deal with that, covered below:

- Option A — Scheduled but still interactive: Windows Task Scheduler launches the script for you at a set time, but only while you're logged in, and you still complete the sign-in prompt when it appears. This automates "remembering to run it" but not the sign-in step.

- Option B — Fully unattended: switch to certificate-based app-only authentication so the script can sign in as an Entra app registration with no human involved, and a scheduled task can run it at 3am with nobody logged in at all. This requires real setup (an app registration, a certificate, and permission grants) and the scripts would need to be updated to use it — not done yet, documented here for when you're ready.

2\. Option A — Scheduled, still interactive

This is the lower-effort option and requires no script changes. Task Scheduler starts PowerShell for you on a schedule; because the task runs in your interactive desktop session, the Exchange Online / Graph sign-in windows appear on your screen just like running it by hand, and you complete them when they pop up.

Setup

1.  Open Task Scheduler (taskschd.msc) → Create Task (not "Basic Task", so you get the full options).

2.  General tab: name it (e.g. "Shared Mailbox Audit + Remediate"). Under "Security options", select "Run only when user is logged on" — this is what allows the sign-in windows to display. Do NOT choose "Run whether user is logged on or not" for this option; that runs in a non-interactive session and the login prompts will never be visible.

3.  Triggers tab → New: set your cadence (e.g. Weekly, Monday, 8:00 AM).

4.  Actions tab → New → Start a program:

Program/script: powershell.exe  
Arguments: -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Audit-SharedMailboxOU.ps1" -Remediate

5.  Conditions/Settings tabs: on a laptop, uncheck "Start the task only if the computer is on AC power" if you want it to run on battery too. Leave "Run task as soon as possible after a scheduled start is missed" checked so a missed run (machine off, asleep) catches up.

6.  Save. When it fires, sign in when prompted — the script otherwise runs exactly as it does today.

Trade-offs

- Only runs the automated part if you're logged in at trigger time — if your machine is off, asleep, or you're logged out, it either skips or waits (per the "missed run" setting) until you're back.

- Still needs you to notice and complete the sign-in prompt — if you're away from the keyboard when it fires, the task sits there waiting.

- Zero new credentials or permissions to manage — it uses your own admin rights exactly as an interactive run does.

3\. Option B — Fully unattended (documented for later)

This removes the human sign-in step entirely by authenticating as an Entra app registration with a certificate instead of a person. This is the only way to get a true "runs by itself at 3am" schedule. It's more setup, and it introduces a credential (the certificate) that can act with the app's permissions with no user context or MFA — so it needs to be locked down properly. The scripts in this package do not currently support this; the steps below are what would need to happen before they could.

3.1 Register an Entra app

1.  Entra admin center → Applications → App registrations → New registration. Name it something identifiable (e.g. "Shared-Mailbox-Cleanup-Automation"), single tenant.

2.  Note the Application (client) ID and Directory (tenant) ID from the app's Overview page — the script will need both.

3.2 Create and attach a certificate

Generate a self-signed certificate (fine for this purpose since it's only used for app authentication, not public trust) on the machine that will run the scheduled task:

\$cert = New-SelfSignedCertificate -Subject "CN=SharedMailboxCleanupAutomation" \`  
-CertStoreLocation "Cert:\CurrentUser\My" -KeySpec Signature -KeyLength 2048 \`  
-NotAfter (Get-Date).AddYears(2)  
Export-Certificate -Cert \$cert -FilePath "C:\Secure\SharedMailboxCleanup.cer"

Upload the .cer (public key only — never the private key) to the app registration: Certificates & secrets → Certificates → Upload certificate. Keep the private key protected in the certificate store on the automation machine; don't export or copy it elsewhere.

3.3 Grant Microsoft Graph application permissions

On the app registration: API permissions → Add a permission → Microsoft Graph → Application permissions, and add:

- User.ReadWrite.All

- Group.ReadWrite.All

- GroupMember.ReadWrite.All

- Directory.Read.All

Then click "Grant admin consent" — application permissions don't work until a Global Administrator (or Privileged Role Administrator) explicitly consents.

3.4 Grant Exchange Online app-only access

Graph permissions don't cover Exchange Online cmdlets like Set-Mailbox or Remove-DistributionGroupMember — that needs a separate app-only grant:

1.  API permissions → Add a permission → APIs my organization uses → search "Office 365 Exchange Online" → Application permissions → Exchange.ManageAsApp → Add, then Grant admin consent.

2.  Assign the app an Exchange role via Entra ID role assignment (not an Exchange RBAC role): Entra admin center → Roles & administrators → Exchange Administrator → Assignments → add the app's service principal (search by the app name). This is what actually lets the app-only session manage mailboxes and groups, not just the API permission grant.

3.5 What the scripts would need to change

Both Connect-ExchangeOnline and Connect-MgGraph calls in the scripts would switch from interactive to certificate-based:

Connect-ExchangeOnline -CertificateThumbprint \$cert.Thumbprint \`  
-AppId "\<application-client-id\>" -Organization "yourtenant.onmicrosoft.com"  
  
Connect-MgGraph -ClientId "\<application-client-id\>" -TenantId "\<tenant-id\>" \`  
-CertificateThumbprint \$cert.Thumbprint -NoWelcome

The client ID, tenant ID, and certificate thumbprint would become new script parameters (or a small config block, same pattern as the Shared Mailbox OU default), pulled from the automation machine's certificate store rather than typed in each run.

3.6 Schedule it fully unattended

With app-only auth in place, Task Scheduler no longer needs an interactive session:

1.  Security options → "Run whether user is logged on or not", using a dedicated low-privilege service account (not a personal admin login) as the "Run as" identity.

2.  Grant that service account read access to the certificate's private key (Manage Private Keys in the certificate's properties) so the scheduled task can use it non-interactively.

3.  Same trigger and action setup as Option A, minus needing anyone logged in.

Security notes for app-only automation

- Scope the app to exactly the four Graph permissions and the one Exchange role above — nothing broader. This app can act tenant-wide within those permissions with no per-action user identity attached.

- Protect the certificate's private key with restrictive ACLs; treat it like a production secret, not a file to copy around or email.

- Set a certificate expiry (2 years above) and calendar a renewal — an expired cert fails closed (the scheduled task starts erroring), which is safer than it failing open, but plan for it rather than discovering it during an incident.

- Review the app's sign-in and audit logs periodically (Entra admin center → Enterprise applications → the app → Sign-in logs) since there's no human session to notice something's wrong.

- Consider a dedicated, low-privilege service account (not a personal or Domain Admin account) as the "Run as" identity for the scheduled task itself, separate from the app registration's own permissions.
