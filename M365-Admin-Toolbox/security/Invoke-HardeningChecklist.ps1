<#
.SYNOPSIS
Exports a production hardening checklist for the toolbox.
.DESCRIPTION
Writes a static text checklist covering authentication, secrets, code signing, logging,
least-privilege, retry behavior, testing, and operational review practices recommended before
running this toolbox unattended in production.
.PARAMETER OutputTxt
Path to write the hardening checklist text file.
.EXAMPLE
.\security\Invoke-HardeningChecklist.ps1
.EXAMPLE
.\security\Invoke-HardeningChecklist.ps1 -OutputTxt .\reports\PreProdHardeningChecklist.txt
#>
param([string]$OutputTxt = '.\reports\HardeningChecklist.txt')

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
$outputFolder = Split-Path $OutputTxt -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }

try {
    $content = @"
Production hardening checklist
=============================
1. Use app-only auth where unattended execution is required.
2. Store secrets in SecretManagement/SecretStore or approved enterprise vault.
3. Sign scripts with a valid code-signing certificate.
4. Enable transcript logging and central log retention.
5. Use least-privilege Graph scopes and admin roles.
6. Validate retry behavior for Graph throttling and transient failures.
7. Test all bulk workflows in a non-production tenant.
8. Restrict report output storage and secure exported data.
9. Rotate certificates and review automation identities regularly.
10. Review scheduled tasks and runbooks for execution context and module availability.
"@
    Set-Content -Path $OutputTxt -Value $content -Encoding UTF8
    Write-ToolboxLog -TenantName 'GLOBAL' -Level 'SUCCESS' -Message "Hardening checklist exported to $OutputTxt"
}
catch {
    Write-ToolboxLog -TenantName 'GLOBAL' -Level 'ERROR' -Message "Hardening checklist export failed: $($_.Exception.Message)"
    throw
}
