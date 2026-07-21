# 06-HybridDynamicGroupBridge

Bridges local AD group membership into cloud-only (Intune/Entra-created)
dynamic groups. Read this whole README before running anything — the
setup script has a one-way step.

## The core problem this solves
Entra ID dynamic group membership rules **cannot reference group
membership** — there's no `user.memberOf` you can test against, on-prem
or cloud. So "auto-add anyone in this local AD group to that cloud group"
isn't directly expressible as a rule. This is a common point of confusion
because it feels like it should exist.

## The workaround (what these two scripts do)
1. **`Sync-ADGroupTagToExtensionAttribute.ps1`** (runs on-prem, scheduled)
   Checks membership in whatever local AD security groups you map, and
   stamps a delimited tag string onto an unused `extensionAttribute` on
   each user (e.g. `;APP1TAG;APP2TAG;`).
2. **Entra Connect syncs that attribute up automatically** —
   extensionAttribute1–15 sync by default, no schema extension work
   required on your part.
3. **`Set-EntraDynamicGroupRule.ps1`** (one-time, per cloud group) — sets
   the existing Intune-side group's membership rule to match that tag,
   e.g. `(user.extensionAttribute15 -contains ";APP1TAG;")`.

Once both are in place, the day-to-day workflow is exactly what you
described: add a user to the mapped **local AD group** → next scheduled
run of script 1 stamps the tag → next Entra Connect cycle syncs it → the
cloud dynamic group picks them up on its own. No manual add to the cloud
group required.

---

## Sync-ADGroupTagToExtensionAttribute.ps1

Runs on-prem, on a domain-joined host, with the ActiveDirectory (RSAT) module
available. Reads membership of one or more local AD security groups and
stamps a delimited tag string onto each affected user's `extensionAttribute`.

### Parameters
| Parameter | Notes |
|---|---|
| `TriggerEntraConnectSync` | After a real (non-WhatIf) run that changed at least one user, remotely triggers a delta sync on `$Config.EntraConnectServer` via `Invoke-Command` |
| `WhatIfOnly` | Preview every add/change/clear with no writes to AD |

### CONFIGURATION block (`$Config`, top of script)
| Variable | Purpose |
|---|---|
| `ADServer` | DC to query |
| `SearchBase` | Scope of users to consider |
| `TargetExtensionAttribute` | Which extensionAttribute (1–15) carries the tag — pick one nothing else uses |
| `TagDelimiter` | Wraps each tag (`;TAG;`) so `-contains` substring matching in the dynamic rule can't false-positive on overlapping names |
| `GroupTagMap` | Local AD group name → tag string. One entry per cloud group you're bridging |
| `EntraConnectServer` / `EntraConnectSyncCommand` | Used only with `-TriggerEntraConnectSync` |
| `ThrottleDelayMs` | Pause (ms) between each `Set-ADUser` write, to avoid hammering the DC on large runs. `0` disables |

### Behavior notes
- **Idempotent and additive-safe** — only writes to AD when a user's
  computed tag actually changes, and correctly clears tags for users
  removed from a mapped group (checked by including anyone who currently
  has a non-empty attribute value, not just current group members).
- Supports multiple tags per user (someone in two mapped groups gets both
  tags in one delimited string) — this is why the delimiter/wrapping
  matters for the dynamic rule's `-contains` match on the other side.
- `-WhatIfOnly` previews every change with no writes.
- AD reads/writes (module import, `Get-ADUser`, `Set-ADUser`) are wrapped in
  try/catch — a missing module, unreachable DC, or per-user write failure
  produces a clear error/warning instead of an unhandled exception.

### Prerequisites
- Must run from a **domain-joined host** with the **ActiveDirectory (RSAT)
  module** installed — this script does not use Graph and does not call
  `Assert-M365Connection`.
- An account with write permission to the `extensionAttribute` in question
  on the users under `SearchBase`.

### Usage
```powershell
# Preview first
.\Sync-ADGroupTagToExtensionAttribute.ps1 -WhatIfOnly

# Real run, and kick a sync afterward
.\Sync-ADGroupTagToExtensionAttribute.ps1 -TriggerEntraConnectSync
```
Schedule this the same way as your existing department-field automation —
same DC, same idea, just a different attribute.

---

## Set-EntraDynamicGroupRule.ps1

### ⚠️ Read before running
Converting an existing group to dynamic membership **replaces its
membership model** — any members added manually/statically are dropped
once the dynamic rule takes over. The script snapshots and prints current
members before doing anything, specifically so you can fold anyone
important into the mapped local AD group first (so they get re-added via
the tag instead of falling out). It refuses to proceed without an explicit
`-Confirmed` flag.

### Prerequisites
- At least one **Entra ID P1** license in the tenant — dynamic group
  membership requires it tenant-wide, not per-group.
- Graph scope `Group.ReadWrite.All` (requested via `Assert-M365Connection`
  / the shared `00-Setup\Connect-M365Services.ps1` connection helper).

### Parameters
| Parameter | Notes |
|---|---|
| `GroupName` | The existing cloud-only group to convert. Must resolve to exactly one group — the script errors out if zero or more than one group share that display name |
| `Tag` | Must match a value from `$Config.GroupTagMap` in the other script |
| `Confirmed` | Required — this is a one-way membership model change |
| `AuthMode` | `Interactive` / `AppSecret` / `Certificate`, passed through to `Assert-M365Connection` |

### CONFIGURATION block (`$Config`, top of script)
| Variable | Purpose |
|---|---|
| `ExtensionAttribute` | Which extensionAttribute (1–15) the dynamic rule reads — **must match** `TargetExtensionAttribute` in `Sync-ADGroupTagToExtensionAttribute.ps1` (default `extensionAttribute15` in both) |
| `TagDelimiter` | Must match `TagDelimiter` in the other script — wraps the tag in the rule's `-contains` match |

### Usage
```powershell
# Review current members first (no changes without -Confirmed)
.\Set-EntraDynamicGroupRule.ps1 -GroupName "Intune-App1-Admins" -Tag "APP1TAG"

# Once you've confirmed the member list is safe to drop/re-derive
.\Set-EntraDynamicGroupRule.ps1 -GroupName "Intune-App1-Admins" -Tag "APP1TAG" -Confirmed
```

## End-to-end setup order
1. Decide which cloud groups you want bridged and pick a tag name for each.
2. Fill in `GroupTagMap` in `Sync-ADGroupTagToExtensionAttribute.ps1` —
   create (or designate) the corresponding local AD security groups if
   they don't already exist.
3. Run that script once with `-WhatIfOnly` to sanity check, then for real.
4. Confirm the tag shows up in Entra ID after a sync cycle:
   `Get-MgUser -UserId <upn> -Property extensionAttribute15`
5. Run `Set-EntraDynamicGroupRule.ps1` against each target cloud group
   (review the printed member snapshot first).
6. From now on: manage membership by adding/removing people from the
   **local AD groups** — the cloud groups take care of themselves.

## Known gotchas
- Initial dynamic rule evaluation against your whole user base can take
  a while the first time a group converts — minutes to a couple hours,
  not instant. Ongoing updates (once it's already dynamic) are faster,
  typically within minutes of the attribute syncing.
- `-contains` in dynamic membership rules is a **substring** match, which
  is exactly why tags are wrapped in delimiters (`;APP1TAG;`) rather than
  matched bare — otherwise `"VIP"` would also match `"APP1TAG"`.
- If you ever need a user in a mapped tag group *without* being in the
  corresponding local AD group (an exception case), you have two options:
  add them to the local group anyway even if it doesn't otherwise apply to
  them, or maintain a small manual "exceptions" static group that you
  handle outside this system — dynamic groups can't mix rule-based and
  manual membership.
