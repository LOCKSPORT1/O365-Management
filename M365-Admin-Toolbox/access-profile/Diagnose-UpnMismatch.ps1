<#
.SYNOPSIS
    Read-only. Compares each user's AD UPN, Entra UPN and suffix casing against the tenant's
    verified domains, to show why a UPN misbehaves.

.DESCRIPTION
    Changes nothing. Answers in one pass:
      1. What UPN does AD actually hold?
      2. What does Entra hold, and does it match the on-premises value?
      3. Is the suffix a verified tenant domain, and is it stored in the same CASE as the
         verified domain?

    That last check is the point. Authentication treats a UPN domain case-insensitively, so
    'JSmith@contoso.com' signs in perfectly - but the Entra portal matches the stored
    suffix against its verified-domain list as a plain string, and those are lowercase. A
    mixed-case suffix therefore shows an EMPTY domain dropdown on the user's Identity blade,
    which reads as "the UPN was never set". Comparisons here are deliberately case-sensitive
    (-cne / -ccontains); PowerShell's default -ne would call these values equal and hide the
    entire problem.

    A UserPrincipalName that differs from OnPremisesUserPrincipalName by more than case means
    Entra Connect rewrote the suffix, which it does when the on-premises suffix is not a
    verified tenant domain.

.PARAMETER SamAccountNames
    One or more AD logon names to inspect.

.EXAMPLE
    .\Diagnose-UpnMismatch.ps1 -SamAccountNames JDoe2,ASmith,BJones
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]]$SamAccountNames
)

$ErrorActionPreference = 'Stop'
$Script:ScriptVersion = "2026-08-06.2 (suffix verdict now reads the ENTRA-stored UPN, not the AD one - checking AD gave a false all-clear before the fix had synced)"
Import-Module ActiveDirectory -ErrorAction Stop

Write-Host "`nDiagnose-UpnMismatch  $Script:ScriptVersion" -ForegroundColor DarkGray
Write-Host "Read-only - nothing is changed.`n" -ForegroundColor DarkGray

Write-Host "=== Tenant verified domains ===" -ForegroundColor Cyan
$verified = @()
try {
    if (-not (Get-MgContext)) {
        Connect-MgGraph -Scopes "User.Read.All", "Domain.Read.All" -NoWelcome
    }
    $domains = Get-MgDomain
    $domains | Select-Object Id, IsVerified, IsDefault, AuthenticationType | Format-Table -AutoSize
    $verified = @($domains | Where-Object IsVerified | Select-Object -ExpandProperty Id)
}
catch {
    Write-Warning "Couldn't read tenant domains: $($_.Exception.Message)"
}

Write-Host "=== Forest-registered UPN suffixes ===" -ForegroundColor Cyan
try {
    $forest = Get-ADForest
    @(@($forest.UPNSuffixes) + @($forest.Domains)) | Where-Object { $_ } | Sort-Object -Unique |
        ForEach-Object { Write-Host "  $_" }
}
catch { Write-Warning "Couldn't read forest suffixes: $($_.Exception.Message)" }

Write-Host "`n=== Per-user comparison ===" -ForegroundColor Cyan
foreach ($sam in $SamAccountNames) {
    $ad = $null
    try { $ad = Get-ADUser -Identity $sam -Properties UserPrincipalName, mail, whenCreated } catch { }

    if (-not $ad) {
        Write-Host "  $sam : not found in AD" -ForegroundColor Red
        continue
    }

    $cloud = $null
    try {
        $cloud = Get-MgUser -UserId $ad.UserPrincipalName `
                 -Property Id, UserPrincipalName, OnPremisesUserPrincipalName, UsageLocation `
                 -ErrorAction Stop
    }
    catch { }

    # Evaluate the suffix Entra actually stores, not the one AD holds. The portal matches
    # against ITS OWN copy, so checking the AD value reports "will prefill" the moment AD is
    # corrected - before the change has synced - which is a false all-clear. Fall back to the
    # AD value only when the user isn't in Entra at all.
    $suffixSource = if ($cloud -and $cloud.UserPrincipalName -match '@') { 'Entra' } else { 'AD' }
    $suffixUpn    = if ($suffixSource -eq 'Entra') { $cloud.UserPrincipalName } else { $ad.UserPrincipalName }
    $suffix = if ($suffixUpn -match '@') { $suffixUpn.Split('@')[1] } else { '' }

    Write-Host "  $sam" -ForegroundColor White
    Write-Host "    AD UPN            : $($ad.UserPrincipalName)"
    Write-Host "    AD mail           : $(if ($ad.mail) { $ad.mail } else { '(none)' })"
    Write-Host "    Created           : $($ad.whenCreated)"

    if ($cloud) {
        Write-Host "    Entra UPN         : $($cloud.UserPrincipalName)"
        Write-Host "    Entra on-prem UPN : $($cloud.OnPremisesUserPrincipalName)"
        Write-Host "    Usage location    : $(if ($cloud.UsageLocation) { $cloud.UsageLocation } else { '(empty)' })" `
            -ForegroundColor $(if ($cloud.UsageLocation) { 'Gray' } else { 'Yellow' })

        if ($cloud.OnPremisesUserPrincipalName -and
            $cloud.UserPrincipalName -ne $cloud.OnPremisesUserPrincipalName) {
            Write-Host "    -> Entra Connect REWROTE the suffix. The on-premises suffix is probably not a" -ForegroundColor Yellow
            Write-Host "       verified tenant domain. Verify the domain, then re-sync." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "    Entra             : not found by this UPN" -ForegroundColor Yellow
    }

    # Case-sensitive AD vs Entra comparison. -ne would call these equal, which is exactly how
    # a not-yet-propagated case fix hides itself.
    if ($cloud -and ($ad.UserPrincipalName -cne $cloud.UserPrincipalName)) {
        if ($ad.UserPrincipalName -eq $cloud.UserPrincipalName) {
            Write-Host "    -> AD and Entra differ by CASE only: AD '$($ad.UserPrincipalName)' vs Entra '$($cloud.UserPrincipalName)'." -ForegroundColor Yellow
            Write-Host "       The AD fix hasn't propagated. Entra Connect compares case-insensitively, so a" -ForegroundColor Yellow
            Write-Host "       delta may see no change. Wait for the cycle to finish, then re-check; if it" -ForegroundColor Yellow
            Write-Host "       still lags, try -PolicyType Initial." -ForegroundColor Yellow
        }
        else {
            Write-Host "    -> AD and Entra hold different UPNs entirely." -ForegroundColor Red
        }
    }

    if ($suffix) {
        if ($verified.Count -eq 0) {
            Write-Host "    Suffix check      : skipped (no verified-domain list)" -ForegroundColor DarkYellow
        }
        # -ccontains is case-SENSITIVE, matching how the portal compares.
        elseif ($verified -ccontains $suffix) {
            Write-Host "    Suffix check ($suffixSource) : '$suffix' matches a verified domain exactly - portal will prefill" -ForegroundColor Green
        }
        elseif ($verified -contains $suffix) {
            $correct = @($verified | Where-Object { $_ -eq $suffix })[0]
            Write-Host "    Suffix check ($suffixSource) : CASE MISMATCH. Stored '$suffix', verified domain is '$correct'." -ForegroundColor Yellow
            Write-Host "       Authentication is fine, but the portal's domain dropdown will read BLANK." -ForegroundColor Yellow
            Write-Host "       Fix: .\Repair-UpnSuffixCase.ps1 -SamAccountNames $sam -Apply" -ForegroundColor Yellow
        }
        else {
            Write-Host "    Suffix check ($suffixSource) : '$suffix' is not a verified domain in this tenant at all." -ForegroundColor Red
        }
    }
    Write-Host ""
}
