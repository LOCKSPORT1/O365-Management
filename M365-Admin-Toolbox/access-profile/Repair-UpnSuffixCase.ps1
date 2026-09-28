<#
.SYNOPSIS
    Lowercases the domain portion of an AD user's UPN so the Entra portal can match it to a
    verified domain and prefill the Identity blade's domain dropdown.

.DESCRIPTION
    Authentication treats a UPN domain case-insensitively, so 'JDoe2@contoso.com' works
    fine. But the Entra portal matches the stored suffix against its verified-domain list as
    a plain string, and those are all lowercase - so a mixed-case suffix shows an EMPTY
    domain dropdown, which looks like the UPN was never set.

    Reports before/after and requires -Apply to change anything. The local part is left
    exactly as-is; only the domain is lowercased.

    IMPORTANT - a case-only change may not register as a delta with Entra Connect, which
    compares values case-insensitively. If the portal still shows a blank dropdown after a
    delta sync, force a full sync on the Entra Connect server:
        Start-ADSyncSyncCycle -PolicyType Initial
    Verify afterwards with:
        Get-MgUser -UserId '<upn>' -Property UserPrincipalName,OnPremisesUserPrincipalName

.PARAMETER SamAccountNames
    One or more AD logon names to inspect. Mutually exclusive with -All.

.PARAMETER All
    Scan every user in the domain and act on all whose UPN suffix isn't already lowercase.
    Reports a count and a breakdown by suffix before touching anything, so you can see the
    scale before deciding. Mutually exclusive with -SamAccountNames.

    Worth running because the capitalisation usually originates at the forest level: if AD
    Domains and Trusts registers the suffix as 'contoso.com', ADUC's UPN dropdown offers
    mixed case and every manually created account inherits it. The problem is rarely limited
    to the accounts you happened to notice.

.PARAMETER SearchBase
    Limit an -All scan to one subtree, e.g. "OU=Company Users,DC=contoso,DC=local".

.PARAMETER Apply
    Actually write the changes. Without it, everything is preview only.

.PARAMETER Force
    Lowercase a suffix even when the lowercased form is NOT a verified tenant domain.

    Off by default, because such a change accomplishes nothing. If a user's suffix is
    'Contoso.Local', lowercasing it to 'contoso.local' leaves it just as unverified - Entra
    Connect will still substitute the UPN, and the portal dropdown will still be blank. Those
    accounts need their suffix REPLACED with a verified domain, which is a different and more
    consequential operation than a case fix, so this script won't quietly do it for you.

.EXAMPLE
    .\Repair-UpnSuffixCase.ps1 -SamAccountNames JDoe2,ASmith
    Preview only. Shows what would change.

.EXAMPLE
    .\Repair-UpnSuffixCase.ps1 -SamAccountNames JDoe2,ASmith -Apply

.EXAMPLE
    .\Repair-UpnSuffixCase.ps1 -All
    Directory-wide audit. Read-only: reports how many users are affected, grouped by suffix.

.EXAMPLE
    .\Repair-UpnSuffixCase.ps1 -All -SearchBase 'OU=Company Users,DC=contoso,DC=local' -Apply
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [string[]]$SamAccountNames,

    [Parameter(Mandatory, ParameterSetName = 'All')]
    [switch]$All,

    [Parameter(ParameterSetName = 'All')]
    [string]$SearchBase,

    [switch]$Apply,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Script:ScriptVersion = "2026-08-06.3 (added -All audit; skips suffixes whose lowercase form isn't a verified tenant domain)"
Import-Module ActiveDirectory -ErrorAction Stop
Write-Host "`nRepair-UpnSuffixCase  $Script:ScriptVersion" -ForegroundColor DarkGray

# Verified tenant domains, if Graph is reachable. Used to avoid a pointless change: lowercasing
# a suffix only helps if the lowercase form is actually a verified domain. 'Contoso.Local'
# lowercased is still not verified, so the edit changes nothing that matters while still
# touching the account. Without Graph we can't tell, so we proceed and say so.
$Script:VerifiedDomains = @()
$Script:VerifiedKnown   = $false
try {
    if (Get-MgContext) {
        $Script:VerifiedDomains = @(Get-MgDomain -ErrorAction Stop | Where-Object IsVerified | Select-Object -ExpandProperty Id)
        $Script:VerifiedKnown   = $true
        Write-Host "Verified tenant domains: $($Script:VerifiedDomains -join ', ')" -ForegroundColor DarkGray
    }
    else {
        Write-Host "Not connected to Graph - can't check suffixes against verified domains." -ForegroundColor DarkYellow
        Write-Host "Run Connect-MgGraph -Scopes 'Domain.Read.All' first for that safety check." -ForegroundColor DarkYellow
    }
}
catch {
    Write-Warning "Couldn't read verified domains: $($_.Exception.Message)"
}

# -All resolves to the full list of users whose UPN suffix is not already lowercase, so the
# audit and the repair use exactly the same comparison. Done here rather than in the loop so
# the count can be reported before anything is touched.
if ($All) {
    Write-Host "Scanning for users whose UPN suffix is not lowercase..." -ForegroundColor Cyan
    $searchParams = @{ Filter = 'UserPrincipalName -like "*"'; Properties = 'UserPrincipalName' }
    if ($SearchBase) { $searchParams.SearchBase = $SearchBase }
    $candidates = @(
        Get-ADUser @searchParams | Where-Object {
            $_.UserPrincipalName -and $_.UserPrincipalName -match '@' -and
            # -cne: case-SENSITIVE. -ne would report zero matches and hide the problem.
            ($_.UserPrincipalName.Split('@')[1] -cne $_.UserPrincipalName.Split('@')[1].ToLowerInvariant())
        }
    )
    $SamAccountNames = @($candidates | Select-Object -ExpandProperty SamAccountName | Sort-Object)
    Write-Host "Found $($SamAccountNames.Count) user(s) with a mixed-case UPN suffix." -ForegroundColor $(if ($SamAccountNames.Count) { 'Yellow' } else { 'Green' })

    if ($SamAccountNames.Count -eq 0) {
        Write-Host "Nothing to do." -ForegroundColor Green
        return
    }

    # Group by suffix so the scale of each variant is obvious at a glance.
    Write-Host ""
    Write-Host "By suffix:" -ForegroundColor Cyan
    $candidates | Group-Object { $_.UserPrincipalName.Split('@')[1] } | Sort-Object Count -Descending |
        ForEach-Object { Write-Host ("  {0,-30} {1} user(s)" -f $_.Name, $_.Count) }
    Write-Host ""
}

$rows = foreach ($sam in $SamAccountNames) {
    $u = $null
    try { $u = Get-ADUser -Identity $sam -Properties UserPrincipalName, mail } catch { }
    if (-not $u) {
        [PSCustomObject]@{ Sam=$sam; Current='(not found in AD)'; Proposed=''; NeedsChange=''; Applied='' }
        continue
    }
    if ($u.UserPrincipalName -notmatch '@') {
        [PSCustomObject]@{ Sam=$sam; Current=$u.UserPrincipalName; Proposed='(no @ in UPN - not touching it)'; NeedsChange=$false; Applied=$false }
        continue
    }
    $parts    = $u.UserPrincipalName -split '@', 2
    $lowSuffix = $parts[1].ToLowerInvariant()
    $proposed = "$($parts[0])@$lowSuffix"
    # -cne: case-SENSITIVE. -ne would call these equal and there'd be nothing to report.
    $needs    = $proposed -cne $u.UserPrincipalName
    $applied  = $false
    $note     = ''

    # Would the lowercased suffix actually be a verified domain? If not, the case fix buys
    # nothing and we skip it unless -Force.
    if ($needs -and $Script:VerifiedKnown -and ($Script:VerifiedDomains -notcontains $lowSuffix)) {
        if (-not $Force) {
            $needs = $false
            $note  = "SKIPPED - '$lowSuffix' is not a verified tenant domain, so lowercasing achieves nothing. This account needs its suffix REPLACED with a verified domain (see -Force in help)."
        }
        else {
            $note = "WARNING - '$lowSuffix' is not a verified tenant domain; proceeding only because -Force was given."
        }
    }

    if ($needs -and $Apply) {
        if ($PSCmdlet.ShouldProcess($sam, "Set UPN to $proposed")) {
            try {
                Set-ADUser -Identity $u.DistinguishedName -UserPrincipalName $proposed -ErrorAction Stop
                $applied = $true
            }
            catch {
                Write-Warning "$sam - $($_.Exception.Message)"
            }
        }
    }

    [PSCustomObject]@{
        Sam         = $sam
        Current     = $u.UserPrincipalName
        Proposed    = $proposed
        NeedsChange = $needs
        Applied     = $applied
        Note        = $note
    }
}

$rows | Format-Table Sam, Current, Proposed, NeedsChange, Applied -AutoSize

$noted = @($rows | Where-Object { $_.Note })
if ($noted) {
    Write-Host ""
    Write-Host "$($noted.Count) account(s) need attention beyond a case fix:" -ForegroundColor Yellow
    foreach ($n in $noted) {
        Write-Host "  $($n.Sam)  [$($n.Current)]" -ForegroundColor Yellow
        Write-Host "    $($n.Note)" -ForegroundColor DarkYellow
    }
}

if (-not $Apply) {
    Write-Host "Preview only - nothing was changed. Re-run with -Apply to write these." -ForegroundColor Yellow
}
else {
    Write-Host "Now trigger a sync on the Entra Connect server. A case-only edit may not" -ForegroundColor Cyan
    Write-Host "register as a delta, so if a delta doesn't take, use -PolicyType Initial." -ForegroundColor Cyan
}
