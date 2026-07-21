# Tests

Starter Pester test suite for the toolbox module. (Expands `docs\README-Testing.md`.)

---

## M365AdminToolbox.Tests.ps1

### What it does
A Pester test file with two `Describe` blocks:

1. **Module import** — force-imports `M365AdminToolbox.psd1` (after removing any already-loaded
   copy of the module) and asserts the module name comes back correctly.
2. **Exported functions** — asserts that `Invoke-M365Connect`, `Invoke-M365UserOnboarding`, and
   `Invoke-M365SecurityAuditExport` are available as commands after import.

These three functions are defined in `public\Public-Functions.ps1` and listed in
`FunctionsToExport` in `M365AdminToolbox.psd1`, so this test also guards against the manifest and
the public function file drifting out of sync (e.g. a function being renamed or removed in one
place but not the other).

### Prerequisites
- [Pester](https://pester.dev/) module (v5+) installed: `Install-Module Pester -Scope CurrentUser`.
- No M365 connection required — these tests only validate module import and command discovery,
  they do not call any Graph/Exchange/Teams/SharePoint cmdlets.

### Example usage
```powershell
# Run directly with Pester
Invoke-Pester -Path .\tests\M365AdminToolbox.Tests.ps1

# Or via the helper script at the repo root
.\Run-Pester.ps1
```

### Extending this suite
If you add new exported functions to `public\Public-Functions.ps1` and `FunctionsToExport` in
`M365AdminToolbox.psd1`, add a matching `It 'exports <FunctionName>'` case here so a future rename
or removal is caught by CI/local test runs rather than discovered at call time. Consider also
adding tests for parameter validation on the wrapped scripts (e.g. that mandatory parameters throw
when omitted) as the suite grows beyond this starter set.
