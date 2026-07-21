<#
.SYNOPSIS
    Applies Authenticode code-signing to toolbox script files.
.DESCRIPTION
    Locates the specified code-signing certificate in the CurrentUser\My certificate store and
    uses it to sign every script file (per the configured file extension list) under the given
    root path (defaults to the toolbox root). Verifies the signature status returned by
    Set-AuthenticodeSignature and logs/throws on failure rather than silently continuing.
.PARAMETER CertificateThumbprint
    Thumbprint of the code-signing certificate to use, looked up in Cert:\CurrentUser\My.
.PARAMETER TimestampServer
    RFC3161 timestamp server URL used to timestamp the signature.
.PARAMETER RootPath
    Root folder to recursively sign scripts under. Defaults to the toolbox root.
.EXAMPLE
    . (Join-Path $PSScriptRoot '..\core\CodeSigning.ps1')
    Sign-ToolboxScripts -CertificateThumbprint 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# File extensions (glob patterns) to include when recursively signing toolbox scripts.
$script:ToolboxSignableExtensions = @('*.ps1', '*.psm1')
# Signature statuses (from Set-AuthenticodeSignature) considered acceptable/successful.
$script:AcceptableSignatureStatuses = @('Valid')

function Sign-ToolboxScripts {
    param(
        [Parameter(Mandatory)][string]$CertificateThumbprint,
        [string]$TimestampServer = 'http://timestamp.sectigo.com',
        [string]$RootPath = ''
    )

    if (-not $RootPath) { $RootPath = Get-ToolboxRoot }
    $cert = Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $CertificateThumbprint }
    if (-not $cert) { throw "Code signing certificate not found: $CertificateThumbprint" }

    $failures = @()
    Get-ChildItem -Path $RootPath -Recurse -Include $script:ToolboxSignableExtensions | ForEach-Object {
        try {
            $sig = Set-AuthenticodeSignature -FilePath $_.FullName -Certificate $cert -TimestampServer $TimestampServer -ErrorAction Stop
            if ($script:AcceptableSignatureStatuses -notcontains $sig.Status.ToString()) {
                $failures += "$($_.FullName): $($sig.Status) - $($sig.StatusMessage)"
                Write-ToolboxLog -Level 'ERROR' -Message "Signing failed for $($_.FullName): $($sig.Status) - $($sig.StatusMessage)"
            } else {
                Write-ToolboxLog -Level 'SUCCESS' -Message "Signed $($_.FullName)."
            }
        }
        catch {
            $failures += "$($_.FullName): $($_.Exception.Message)"
            Write-ToolboxLog -Level 'ERROR' -Message "Signing threw an exception for $($_.FullName): $($_.Exception.Message)"
        }
    }

    if ($failures.Count -gt 0) {
        throw "Code signing failed for $($failures.Count) file(s):`n$($failures -join "`n")"
    }
}
