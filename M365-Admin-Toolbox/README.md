# M365 Admin Toolbox

Multi-tenant PowerShell administration toolbox for Microsoft 365, Entra ID, Intune, Azure, Exchange Online, Purview, hybrid, and cloud-only environments.

## What is included
- Central tenant JSON configuration
- Universal connector script that never assumes services are already connected
- Exchange purge and mailbox audit scripts
- User onboarding and offboarding lifecycle scripts
- Intune device onboarding and offboarding scripts
- Entra group management script
- Azure context helper
- Script-by-script documentation

## Design principles
1. Every operational script can be run independently.
2. Every operational script loads the connector at the top.
3. No script assumes Graph, Exchange, Intune, Azure, or Purview are already connected.
4. Tenant-specific details are stored in `config/tenants.json`.
5. Hybrid and cloud-only tenants are both supported using config flags.

## Folder layout
- `config` - tenant JSON and global defaults
- `core` - shared helper functions and connection bootstrap
- `exchange` - Exchange and Purview operations
- `lifecycle` - user onboarding and offboarding
- `intune` - managed device lifecycle scripts
- `entra` - user/group identity management
- `azure` - Azure context helpers
- `docs` - detailed READMEs
- `samples` - sample runbook starter
- `logs` - action logging output

## Required modules
- Microsoft.Graph.Authentication
- ExchangeOnlineManagement
- MicrosoftTeams (optional when using Teams tasks)
- Microsoft.Online.SharePoint.PowerShell (optional when using SPO tasks)
- Az.Accounts

The connector can auto-install missing modules for the current user.

## First-time setup
1. Open PowerShell 7 as an administrator or privileged admin shell.
2. Unblock the files if needed: `Get-ChildItem -Recurse | Unblock-File`
3. Set script execution policy as appropriate for your organization.
4. Edit `config/tenants.json` and add each tenant.
5. Test a connection:
   `.\core\Connect-M365.ps1 -TenantName Tenant-Example-NA -ConnectGraph -ConnectExchange -ConnectPurview -ConnectAzure -ConnectIntune`

## Authentication models
### Delegated interactive
Use this for manual admin operations. The connector calls `Connect-MgGraph` with scopes and signs in interactively.

### App-only certificate auth
Use this for scheduled tasks and automation. Set `AppRegistration.UseAppOnly` to `true`, populate the client ID and certificate thumbprint, and ensure the certificate private key exists on the automation host.

## Hybrid model
If `OnPrem.Enabled` is true, scripts can branch to an on-prem workflow. This package includes placeholders and documentation for on-prem provisioning, disablement, and OU movement.

## Safety notes
- Always run purge operations against a validated search query first.
- Test lifecycle changes against a pilot user.
- Convert mailboxes to shared only when retention and licensing requirements are understood.
- Review Graph and app permissions using least privilege.


## Bulk and hybrid additions
- `hybrid` contains on-prem AD remoting, hybrid user creation/disable, and AD sync trigger scripts.
- `bulk` contains CSV-driven multi-tenant onboarding, offboarding, and mailbox audit orchestration.
- `templates` contains starter CSV files for bulk workflows.

- Shared mailbox permission reporting
- License inventory and assignment reporting
- Intune stale device reporting and cleanup
- HTML dashboard report generation

- Teams inventory reporting
- SharePoint Online site inventory reporting
- Windows Autopilot device reporting
- Conditional Access policy reporting
- Scheduled task registration example
- Azure Automation / runbook example

- Exchange transport rule reporting
- Mailbox forwarding audits, including optional inbox-rule review
- PIM role assignment reporting
- Compliance audit export script
- Defender for Office 365 starter scaffold

- Transcript logging helpers
- Centralized error handling wrapper
- Retry helper for throttling and transient failures
- SecretManagement and SecretStore integration helpers
- Code-signing helper for PowerShell scripts
- Production hardening checklist generator

- PowerShell module root loader (`M365AdminToolbox.psm1`)
- PowerShell module manifest (`M365AdminToolbox.psd1`)
- Installer script for module deployment
- Bootstrap script for dependency prep and secret-store initialization
- Changelog for release tracking

- Exported advanced-function wrappers for core operational workflows
- Comment-based help on public advanced functions
- Starter Pester tests for module validation
