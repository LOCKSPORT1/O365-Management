# 02-Offboarding — Invoke-M365UserOffboarding.ps1

## What it does
Runs the full user offboarding pipeline as one script instead of a checklist
you have to remember under time pressure. Each step is independently
try/caught so a single failure (e.g. a dynamic group that can't be manually
removed) doesn't stop the rest of the run. All failures are collected and
printed in a summary at the end.

The script supports `-WhatIf` / `-Confirm` (`SupportsShouldProcess`) — every
destructive or irreversible-ish action (account disable, session revoke,
password reset, mailbox conversion, mailbox permission grant, license
removal, group membership changes, on-prem AD disable/move) is wrapped in a
`ShouldProcess` check, so you can dry-run the entire pipeline with `-WhatIf`
before committing to it.

Pipeline order:
1. Disable sign-in (`AccountEnabled = $false`)
2. Revoke active sessions / refresh tokens (`-RevokeSessions`)
3. Reset password to a random value (always runs — belt and suspenders)
4. Convert mailbox to shared + grant manager full access (`-ConvertMailboxToShared`)
5. Set auto-reply/out-of-office (`-SetOutOfOffice`)
6. Remove licenses (`-RemoveLicenses`) — run *after* mailbox conversion
7. Remove from all groups except a retention/holding group
8. Add to retention/holding group for visibility
9. Disable + move on-prem AD account (`-DisableOnPremAD`, `-AddToAD_DisabledOU`)

## Prerequisites
- PowerShell 7.x recommended (see `00-Setup` notes on EXO session reliability on 5.1)
- Modules: `Microsoft.Graph` (or at minimum the `Users`, `Groups`, and
  `Identity.DirectoryManagement` submodules) and `ExchangeOnlineManagement`
- `ActiveDirectory` module only if using `-DisableOnPremAD` (run from/near a DC or a machine with RSAT)
- Graph scopes: `User.ReadWrite.All`, `Group.ReadWrite.All`, `Directory.ReadWrite.All` (see `00-Setup\Connect-M365Services.ps1`)
- Exchange Online role sufficient for `Set-Mailbox`, `Add-MailboxPermission`, and `Set-MailboxAutoReplyConfiguration` (e.g. Recipient Management)
- On-prem: rights to disable/move AD computer accounts if `-DisableOnPremAD`/`-AddToAD_DisabledOU` are used

## Parameters
| Parameter | Type | Notes |
|---|---|---|
| `UserUpn` | Mandatory | The account being offboarded |
| `ManagerUpn` | Optional | Gets mailbox full access + used in OOO message |
| `ConvertMailboxToShared` | Switch | Recommended — preserves mail, frees the license |
| `RevokeSessions` | Switch | Kills active tokens immediately |
| `RemoveLicenses` | Switch | Frees seats for reuse |
| `DisableOnPremAD` | Switch | Only relevant for hybrid-synced accounts |
| `SetOutOfOffice` | Switch | Auto-reply, uses `OutOfOfficeMessage` template |
| `OutOfOfficeMessage` | Optional | Template string; `{0}` is replaced with `-ManagerUpn`, or the `NoManagerContactText` config fallback if no manager was given |
| `AddToAD_DisabledOU` | Switch | Moves the AD object as well as disabling it |
| `AuthMode` | Optional | `Interactive` (default), `AppSecret`, or `Certificate` — passed to `Assert-M365Connection` |
| `WhatIf` | Switch | Dry-run — shows every action that would be taken without making changes |
| `Confirm` | Switch | Prompts before each destructive action |

## Configuration block (`$Config`)
Located right after `param()`, under the standard toolkit banner. Edit these
for your environment before running:

| Variable | Purpose |
|---|---|
| `ADDisabledOU` | Distinguished name of the OU disabled AD accounts get moved into (only used with `-AddToAD_DisabledOU`) |
| `ADServer` | DC (FQDN) used for ActiveDirectory cmdlets |
| `RetentionGroupTag` | Display name of a holding group offboarded users land in instead of losing all group visibility immediately |
| `NinjaCustomFieldNote` | Placeholder reminder — pair this with your NinjaRMM custom-field automation if you want offboarding date tracked there too |
| `NoManagerContactText` | Fallback text used in the out-of-office message when `-ManagerUpn` isn't supplied (avoids a blank "contact  for assistance" message) |

All values shown in the script are placeholders (`yourdomain.com`,
`yourdomain.local`, etc.) — replace with your own tenant's OU paths, DC
name, and group naming convention.

## Usage

Normal run:
```powershell
. ..\00-Setup\Connect-M365Services.ps1
Connect-M365 -Services Graph,ExchangeOnline

.\Invoke-M365UserOffboarding.ps1 -UserUpn "jane.doe@yourdomain.com" `
    -ManagerUpn "john.smith@yourdomain.com" `
    -ConvertMailboxToShared -RevokeSessions -RemoveLicenses `
    -SetOutOfOffice -DisableOnPremAD -AddToAD_DisabledOU
```

Dry run (no changes made — shows what each step would do):
```powershell
.\Invoke-M365UserOffboarding.ps1 -UserUpn "jane.doe@yourdomain.com" `
    -ConvertMailboxToShared -RevokeSessions -RemoveLicenses -WhatIf
```

Prompt before each destructive step:
```powershell
.\Invoke-M365UserOffboarding.ps1 -UserUpn "jane.doe@yourdomain.com" `
    -ConvertMailboxToShared -RemoveLicenses -Confirm
```

## What this does NOT do
- Device retire/wipe in Intune — see `03-DeviceLifecycle/Remove-IntuneDeviceLifecycle.ps1`
- Deauthorizing AnyDesk, CrowdStrike sensor removal, FileCloud account
  cleanup — these aren't Graph/EXO-scriptable in a standard way; keep them
  on a manual checklist or wire them into NinjaRMM automation separately.
- Deleting the AD/Entra object outright — deliberately not automated. Hold
  for your retention window, then delete manually or in a separate cleanup
  pass once legal/HR sign off.

## Known gotchas
- Removing group membership can fail for dynamic groups or role-assignable
  groups — those errors show up in the summary but won't block the rest
  of the run. Handle those manually if they appear.
- `Invoke-MgInvalidateUserRefreshToken` revokes refresh tokens but any
  already-issued access token remains valid for its (short) remaining
  lifetime — pair with disabling the account for immediate effect.
- Steps 1 (disable sign-in), 3 (password reset), and 7-8 (group
  cleanup/retention add) always run regardless of switches — only the
  optional pipeline stages are gated behind their respective `-Switch`
  parameters. Use `-WhatIf` first if you want to confirm exactly what will
  run before committing.
