# Hybrid M365 Automation Toolkit

Production-tested PowerShell automation for hybrid Microsoft 365 environments — on-premises Active Directory synced to Entra ID via Entra Connect, with Exchange Online, Intune, and RMM-managed Windows endpoints.

Everything in this repo is **tenant-agnostic**. No hardcoded org names, OUs, group tags, or tenant IDs — all environment-specific values live in a clearly marked configuration block at the top of each script, and each module's README documents where to find those values in your own tenant.

## What's here

### `M365-Admin-Toolkit/` — User & device lifecycle automation
An 8-module library covering the full identity lifecycle, built on the Microsoft Graph PowerShell SDK and ExchangeOnlineManagement (no deprecated MSOnline/AzureAD modules).

| Module | Covers |
|---|---|
| `00-Setup` | Shared auth helper (`Assert-M365Connection`) — Interactive, App Secret, and Certificate auth modes |
| `01-Onboarding` | Hybrid AD/cloud user creation, department-based license and group assignment |
| `02-Offboarding` | Session revocation, mailbox conversion, license removal, on-prem AD disable |
| `03-DeviceLifecycle` | Intune inventory, retire/wipe/delete (gated behind an explicit `-Confirmed` flag), Autopilot enrollment |
| `04-Reporting-Reconciliation` | License waste, inactive accounts, incomplete-offboarding detection |
| `05-ExchangeManagement` | Shared mailboxes, delegate permissions, message trace, compliance-search email purge |
| `06-HybridDynamicGroupBridge` | Two-stage bridge syncing local AD group membership into cloud-only Entra dynamic groups via extensionAttributes |
| `07-EnvironmentHealthAutomation` | App secret expiry, guest access review, mailbox storage, ownerless groups, MFA registration, stale device cleanup, bulk CSV onboarding |
| `08-AlertingAndScheduling` | Email/Teams notification delivery wired to Windows Scheduled Tasks |

Every script is standalone: it connects to what it needs if not already connected, skips reconnecting if a session exists, and supports `-WhatIf`/`-Confirm` where destructive.

### `M365-Admin-Toolbox/` — Module-based admin framework
A larger, PowerShell-module-style framework (`.psd1`/`.psm1`, Pester tests) covering 15 categories: core plumbing (auth, logging, retry, error handling, secrets, code signing), Entra/Exchange/Intune/Teams/SharePoint/Azure reporting and audits, hybrid AD operations, user lifecycle, access-profile-based provisioning (export a template user's groups/licenses to JSON, apply to new hires), bulk multi-tenant operations, security hardening checks, HTML dashboard reporting, and scheduled-task/Azure Automation examples. Configuration lives in a central `config/tenants.json` supporting multiple tenants. Full runbooks in `docs/`.

### Toolkit vs. Toolbox — which one do I want?
They overlap in purpose but differ in shape. The **Toolkit** is a collection of fully standalone scripts — each one self-connects, carries its own config region, and can be copied out and run in isolation; start here if you want to grab one script and go. The **Toolbox** is a framework — scripts share core plumbing (central tenant config, common logging/retry/auth), support multi-tenant operation, and include tests; start here if you're building out a maintained automation platform. Nothing stops you from using both.


### Roadmap: `Autopilot-Deployment-Kit/` — Zero-touch Windows deployment *(coming soon)*
End-to-end Windows Autopilot bootstrap for a hybrid environment:
- `Invoke-AutopilotBuilder.ps1` — builds profiles, groups, and assignments from a config region
- `Get-EnvironmentInfo.ps1` — discovers your existing tags, groups, and profiles to populate the config
- USB OOBE registration kit (`autopilot.cmd` + `AutopilotRegister.ps1`) — Shift+F10 at OOBE, pick a department from a menu, hardware hash uploads with the right Group Tag. Ships with an offline copy of `Get-WindowsAutopilotInfo` because the PowerShell Gallery fallback reliably fails at OOBE
- Full deployment runbook covering setup, field workarounds, and troubleshooting

### Roadmap: `Fleet-Hardware-Audit/` — External hardware inventory *(coming soon)*
Fleet-wide monitor and docking station audit with parallel collection paths so no endpoint is missed:
- **RMM path** — endpoint script writes JSON to a custom field over the agent's HTTPS channel (no VPN dependency); a reporting script pulls fields via API into CSV
- **Intune path** — Remediations detection script (SYSTEM, 64-bit, weekly) with a self-exclusion guard so RMM-managed machines don't double-report; a Graph-based reporting script merges everything into a master CSV, deduped by computer + monitor serial
- Playbook documenting cadence, CSV schema, and known limitations (e.g., DP-alt-mode dock detection is heuristic; DisplayLink docks resolve definitively via the PnP tree)

### Roadmap: `Endpoint-Scripts/` — RMM-deployable maintenance *(coming soon)*
Standalone scripts built for RMM deployment (NinjaRMM-flavored custom field reporting, easily adapted):
- **MDM diagnostic cleanup** — automated cleanup of MDM diagnostic folders with custom-field status reporting
- **AD department assignment** — scheduled task on a DC that sets AD department attributes from OU membership
- **User profile cleanup** — offboarding profile removal using `Remove-CimInstance Win32_UserProfile` (not folder deletion), with handling for companion service-account profile pairs and cloud-sync reparse points

## Conventions

- **`#region Configuration — EDIT THESE VARIABLES`** at the top of every script separates your environment from the logic. Nothing below the region should need editing.
- **Self-connecting auth** — scripts assert their own Graph/EXO/Compliance connections with an `-AuthMode` parameter (Interactive | AppSecret | Certificate).
- **Safe by default** — destructive operations support `-WhatIf`/`-Confirm`, and irreversible ones (device wipe, purge) additionally require an explicit confirmation flag.
- **Per-module READMEs** document every configurable variable, required Graph scopes, prerequisites, usage examples, and known gotchas.

## Requirements

- PowerShell 5.1+ (7.x recommended)
- `Microsoft.Graph` and `ExchangeOnlineManagement` modules (installed on demand where scripts check for them)
- Appropriate Graph scopes per module (documented in each README); some reports require Entra ID P1/P2 (`signInActivity`)
- For app-only auth: an App Registration with certificate or client secret

## Disclaimer

These scripts perform real changes against production identity and endpoint infrastructure. Review the configuration region and run with `-WhatIf` in your environment before scheduling anything. Provided as-is, without warranty — test in a pilot scope first.

## License

MIT
