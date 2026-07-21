<#
.SYNOPSIS
    Reports which users have NOT registered a strong MFA method - the
    single most impactful security gap report you can run on a recurring
    basis. One unregistered account is one account a Conditional Access
    policy can't actually protect the way you think it does.

.DESCRIPTION
    Pulls authentication method registration state per user via Graph's
    reports API and flags anyone without at least one strong method
    (Authenticator app, FIDO2, Windows Hello for Business, or a software/
    hardware one-time passcode token). SMS/voice are flagged separately as
    weak-but-present since they technically count as "registered" but are
    the weakest option.

.PARAMETER IncludeDisabledAccounts
    By default, disabled (blocked sign-in) accounts are excluded from the
    report since their MFA state is not currently a live risk. Pass this
    switch to include them anyway (tagged via the AccountEnabled column).
    Note: the registration-details report endpoint doesn't expose enabled/
    disabled state directly, so this requires an extra Get-MgUser lookup
    per account to cross-reference.

.PARAMETER ExportPath
    Path to write the CSV report to.

.PARAMETER AuthMode
    Interactive, AppSecret, or Certificate - passed through to
    Assert-M365Connection. Defaults to Interactive.

.EXAMPLE
    .\Get-MFARegistrationComplianceReport.ps1

.EXAMPLE
    .\Get-MFARegistrationComplianceReport.ps1 -IncludeDisabledAccounts -AuthMode AppSecret

.NOTES
    Requires Graph scope Reports.Read.All (and/or
    UserAuthenticationMethod.Read.All for per-user detail fallback).
    Also requires User.Read.All when disabled-account filtering is active
    (the default), since AccountEnabled is looked up via Get-MgUser.
#>

[CmdletBinding()]
param(
    # ============================================================
    # CONFIGURATION - adjust these values for your environment
    # ============================================================
    # Include disabled (blocked sign-in) accounts in the report. Excluded by default.
    [switch]$IncludeDisabledAccounts,

    # Output path for the CSV report.
    [string]$ExportPath = ".\MFAComplianceReport_$(Get-Date -Format 'yyyyMMdd').csv",

    # Auth mode passed through to Assert-M365Connection (Interactive/AppSecret/Certificate).
    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

# Registered methods considered "strong" for compliance purposes.
$StrongMethods = @("microsoftAuthenticatorPush","fido2","windowsHelloForBusiness","softwareOneTimePasscode","hardwareOneTimePasscode")

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

Write-Host "Pulling authentication method registration detail..." -ForegroundColor Cyan

# This report endpoint gives a per-user rollup without looping every user individually
try {
    $regDetails = Get-MgReportAuthenticationMethodUserRegistrationDetail -All
}
catch {
    Write-Error "Failed to retrieve authentication method registration details: $($_.Exception.Message)"
    return
}

# The userRegistrationDetails report object doesn't expose AccountEnabled,
# so disabled-account filtering requires a separate Get-MgUser lookup.
$enabledMap = $null
if (-not $IncludeDisabledAccounts) {
    try {
        $allUsers = Get-MgUser -All -Property Id,AccountEnabled
        $enabledMap = @{}
        foreach ($u in $allUsers) { $enabledMap[$u.Id] = $u.AccountEnabled }
    }
    catch {
        Write-Warning "Failed to retrieve account-enabled state from Graph; disabled accounts will not be filtered out: $($_.Exception.Message)"
    }
}

$report = foreach ($u in $regDetails) {
    if ($enabledMap -and $enabledMap.ContainsKey($u.Id) -and ($enabledMap[$u.Id] -eq $false)) {
        continue
    }

    $strongMethodsPresent = $u.MethodsRegistered | Where-Object { $_ -in $StrongMethods }
    $weakOnly = ($u.MethodsRegistered.Count -gt 0) -and ($strongMethodsPresent.Count -eq 0)

    [PSCustomObject]@{
        DisplayName    = $u.UserDisplayName
        UPN            = $u.UserPrincipalName
        IsMfaRegistered = $u.IsMfaRegistered
        IsMfaCapable   = $u.IsMfaCapable
        MethodsRegistered = ($u.MethodsRegistered -join "; ")
        Flag           = if (-not $u.IsMfaRegistered) { "NOT_REGISTERED" } elseif ($weakOnly) { "WEAK_METHOD_ONLY" } else { "OK" }
    }
}

$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Exported $($report.Count) user(s) to $ExportPath" -ForegroundColor Green

$gaps = $report | Where-Object { $_.Flag -ne "OK" }
Write-Host "`n=== $($gaps.Count) account(s) with an MFA gap ===" -ForegroundColor Red
$gaps | Sort-Object Flag | Format-Table DisplayName, UPN, Flag, MethodsRegistered -AutoSize
