# Production hardening

## Logging.ps1
Provides transcript start/stop helpers built around `Start-Transcript`.

## ErrorHandling.ps1
Provides a centralized safe execution wrapper using `try`, `catch`, and `finally`.

## Retry.ps1
Provides retry and backoff handling for throttling and transient failures.

## Secrets.ps1
Provides helper functions for PowerShell SecretManagement and SecretStore.

## CodeSigning.ps1
Provides a bulk signing helper using `Set-AuthenticodeSignature` and a code-signing certificate.

## Invoke-HardeningChecklist.ps1
Exports a deployment hardening checklist for production rollout.


## Testing direction
Use Pester to validate exported functions and module imports before promoting a release.
