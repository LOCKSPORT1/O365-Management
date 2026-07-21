# Base operating instructions

## How the scripts connect
Every task script starts by loading `core\Common.ps1` and calling `core\Connect-M365.ps1` with the exact services it needs.

Examples:
- Graph only tasks: onboarding, Entra group management
- Graph + Exchange: offboarding with mailbox work
- Exchange + Purview: email purge
- Graph + Intune: device onboarding and offboarding
- Azure: context helper and Azure automation extensions

## Why the connector is at the top of every script
This package is designed for independent execution. A script can be launched directly by an administrator, scheduled task, Azure Automation worker, or runbook without a pre-connected shell.

## How configuration works
- `GlobalSettings` hold broad defaults.
- Each object in `Tenants` defines the tenant identity and its hybrid/cloud characteristics.
- You can duplicate a tenant block to add more tenants.
- Location, region, OU path, and cloud defaults are all data-driven, not hardcoded into scripts.

## Security recommendations
- Prefer certificate-based app-only auth for unattended jobs.
- Keep delegated auth for human-run tasks.
- Review Graph permissions and Exchange roles before production use.
- Store certificates in the computer certificate store on the automation host.

## Extending the package
Add new scripts under the relevant folder and follow this pattern:
1. Import `Common.ps1`
2. Call `Connect-M365.ps1` with the required service switches
3. Load tenant config if you need tenant-specific values
4. Execute the task
5. Write a log entry and optional report output


## Hybrid AD notes
The hybrid scripts rely on the ActiveDirectory module and PowerShell remoting to the configured on-prem remote host. The AD cmdlets used in the package align with standard Active Directory PowerShell operations such as `New-ADUser`, `Disable-ADAccount`, and `Move-ADObject`.

## Bulk processing notes
Bulk scripts are CSV-driven so a single run can process multiple tenants in one pass. The result of each row is written to a report CSV for audit and retry handling.


## Reporting notes
The new reporting layer is CSV-first and includes an HTML dashboard generator that summarizes discovered report files in the reports folder. This makes it easier to hand off outputs to another admin or archive them with tickets.


## Scheduling notes
For Windows Task Scheduler, use the provided registration example and run the package from a host that has all required modules, certificates, and network access. For Azure Automation, shift tenant authentication to app-only auth and validate module availability before production rollout.


## Security reporting notes
The v5 package adds transport rule reporting, forwarding audits, PIM reporting, and compliance audit exports. Review record types, retention windows, and role requirements before scheduling these reports.


## Production hardening notes
The v6 package adds helpers for transcripts, safe execution, retry/backoff logic, secret storage, and code signing. These controls are intended to be enabled before unattended or large-scale production use.
