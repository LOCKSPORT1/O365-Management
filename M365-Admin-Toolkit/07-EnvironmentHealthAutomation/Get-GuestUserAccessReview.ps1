<#
.SYNOPSIS
    Reports all Entra ID guest (B2B) users with last sign-in and group/
    Teams membership, flagging stale guests as removal candidates.

.DESCRIPTION
    Guest accounts are one of the most commonly forgotten cleanup items -
    added for a project, a shared Teams channel, a one-time file share,
    and then never removed. Each one is a standing access footprint.
    This report flags anyone who hasn't signed in within the threshold
    window (or never has) so you have a concrete list for a periodic
    access review instead of relying on memory.

.PARAMETER StaleThresholdDays
    Number of days without a sign-in before a guest is flagged stale
    (default 90).

.PARAMETER ExportPath
    Path to write the CSV report to.

.PARAMETER AuthMode
    Interactive, AppSecret, or Certificate - passed through to
    Assert-M365Connection. Defaults to Interactive.

.EXAMPLE
    .\Get-GuestUserAccessReview.ps1 -StaleThresholdDays 90

.EXAMPLE
    .\Get-GuestUserAccessReview.ps1 -StaleThresholdDays 60 -AuthMode Certificate

.NOTES
    Requires Graph scopes User.Read.All and AuditLog.Read.All
    (signInActivity needs Entra ID P1/P2).
#>

[CmdletBinding()]
param(
    # ============================================================
    # CONFIGURATION - adjust these values for your environment
    # ============================================================
    # Number of days without a sign-in before a guest is flagged stale.
    [int]$StaleThresholdDays = 90,

    # Output path for the CSV report.
    [string]$ExportPath = ".\GuestAccessReview_$(Get-Date -Format 'yyyyMMdd').csv",

    # Auth mode passed through to Assert-M365Connection (Interactive/AppSecret/Certificate).
    [ValidateSet("Interactive","AppSecret","Certificate")]
    [string]$AuthMode = "Interactive"
)

#region Connect - ensures the required session is live before proceeding
. "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
Assert-M365Connection -Services Graph -AuthMode $AuthMode
#endregion

Write-Host "Pulling all guest users..." -ForegroundColor Cyan
try {
    $guests = Get-MgUser -All -Filter "userType eq 'Guest'" -Property Id,DisplayName,Mail,UserPrincipalName,CreatedDateTime,SignInActivity,ExternalUserState
}
catch {
    Write-Error "Failed to retrieve guest users from Graph: $($_.Exception.Message)"
    return
}

$cutoff = (Get-Date).AddDays(-$StaleThresholdDays)

$report = foreach ($g in $guests) {
    $lastSignIn = $g.SignInActivity.LastSignInDateTime
    try {
        $memberOf = Get-MgUserMemberOf -UserId $g.Id -All
    }
    catch {
        Write-Warning "Failed to retrieve group memberships for $($g.UserPrincipalName): $($_.Exception.Message)"
        $memberOf = @()
    }
    $groupNames = ($memberOf | ForEach-Object { $_.AdditionalProperties.displayName }) -join "; "

    [PSCustomObject]@{
        DisplayName    = $g.DisplayName
        Email          = $g.Mail
        UPN            = $g.UserPrincipalName
        InvitedOn      = $g.CreatedDateTime
        LastSignIn     = $lastSignIn
        NeverSignedIn  = -not $lastSignIn
        InviteStatus   = $g.ExternalUserState
        GroupMemberships = $groupNames
        StaleFlag      = ((-not $lastSignIn) -or ($lastSignIn -lt $cutoff))
    }
}

$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Exported $($report.Count) guest account(s) to $ExportPath" -ForegroundColor Green

$stale = $report | Where-Object StaleFlag
Write-Host "`n=== Stale guest review candidates: $($stale.Count) / $($report.Count) ===" -ForegroundColor Yellow
$stale | Format-Table DisplayName, Email, LastSignIn, GroupMemberships -AutoSize
