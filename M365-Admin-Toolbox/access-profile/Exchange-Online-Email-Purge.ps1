<#
===============================================================================
 Exchange Online Email Purge Script
===============================================================================
PURPOSE
  Finds and permanently removes a specific email (matched by sender + subject)
  from mailboxes across a Microsoft 365 tenant, using the supported Microsoft
  Purview Content Search + Purge workflow. Typically used for incident
  response (phishing, accidental send, malicious email) when a message needs
  to be pulled from recipient inboxes after delivery.

PREREQUISITES (check these BEFORE running, in order)
  1. ExchangeOnlineManagement PowerShell module, version 3.9.0 or later.
       Get-Module ExchangeOnlineManagement -ListAvailable
       Install-Module ExchangeOnlineManagement -Force   (if missing/outdated)

  2. Your account must be in a role group that has the "Search and Purge"
     role. This is NOT included in eDiscovery Manager by default -- only
     Organization Management and Data Investigator have it by default.
       Check in Microsoft Purview portal (compliance.microsoft.com):
         Roles & scopes > Permissions > find your role group > confirm
         "Search and Purge" is listed.
       Or add yourself to Organization Management (requires admin):
         Add-RoleGroupMember -Identity "Organization Management" -Member <you>
     If this role is missing, the purge step will either error out or
     silently report success with "Item count: 0" -- it LOOKS like it ran
     but nothing was actually deleted.

  3. Run this in a BRAND NEW PowerShell window with nothing else imported --
     in particular, do NOT have Microsoft.Graph modules loaded in the same
     session. Mixing them with ExchangeOnlineManagement can cause a crash:
       "The type initializer for
        'Microsoft.Exchange.Configuration.Authorization.InitialSessionStateBuilder'
        threw an exception."
     If you hit that error, close ALL PowerShell windows and start fresh.

KNOWN LIMITS / THINGS THAT WILL CONFUSE YOU IF YOU DON'T KNOW THEM UP FRONT
  - Purge removes a MAXIMUM of 10 items per mailbox per purge action. This
    script automatically loops (re-searches + re-purges) if any mailbox has
    more than 10 matching items, until nothing is left or 10 rounds pass.
  - Message Trace (in the Exchange admin center) is a permanent delivery LOG,
    completely separate from mailbox content. It will keep showing the
    message as "Delivered" forever (subject to its retention window,
    typically ~90 days) even after a successful purge. Do NOT use Message
    Trace to verify a purge -- it is not a mailbox-content check.
  - The Content Search index can lag a few minutes to an hour behind actual
    mailbox state. If you immediately re-run a search to "verify" the purge,
    it may show stale results. Wait before re-checking, or verify directly
    in a mailbox (see VERIFICATION below).
  - HardDelete is IRREVERSIBLE (bypasses Recoverable Items / Deleted Items
    entirely). SoftDelete is recoverable by the end user until their deleted
    item retention period expires. Choose deliberately.

RECOMMENDED FIRST-TIME TEST PROCEDURE
  Before relying on this for a real incident, test it end-to-end:
    1. From an external/personal email account (outside your tenant), send a
       test email to one internal test mailbox, with a unique, unmistakable
       subject line (e.g. "PURGE-TEST-<date>-<random>").
    2. Confirm it was delivered (check the mailbox, or Message Trace).
    3. Run this script with that exact sender address and subject, targeting
       just that one test mailbox (enter it when prompted for mailboxes
       instead of leaving blank for "All").
    4. Verify using the VERIFICATION steps at the bottom of this file.
  This confirms your permissions, module version, and workflow all work
  before you ever need it under time pressure.

VERIFICATION (ground truth, in order of reliability)
  1. The script's own final "Results" output, e.g.:
       Purge Type: HardDelete; Item count: 3; ... Failed count: 0
     This is Microsoft's own authoritative record that the purge succeeded.
     A "Failed count: 0" per mailbox is real confirmation, not a guess.
  2. Direct mailbox check: grant yourself temporary Full Access, search
     every folder in that mailbox by hand, then revoke access:
       Connect-ExchangeOnline -UserPrincipalName <admin>
       Add-MailboxPermission -Identity <mailbox> -User <admin> `
         -AccessRights FullAccess -InheritanceType All -AutoMapping $false
       # ... check via OWA "Open another mailbox", search all folders ...
       Remove-MailboxPermission -Identity <mailbox> -User <admin> `
         -AccessRights FullAccess -Confirm:$false
  3. A FRESH content search (search only, no purge) re-run 30-60 minutes
     later for the same query, expecting Items: 0. Don't trust this
     immediately after a purge -- see index lag note above.

===============================================================================
#>

# ---- Step 0: Environment fixes ----
# Known workaround for the ExchangeOnlineManagement "InitialSessionStateBuilder"
# crash -- force en-US culture before the module loads anything.
[System.Threading.Thread]::CurrentThread.CurrentCulture   = New-Object System.Globalization.CultureInfo("en-US")
[System.Threading.Thread]::CurrentThread.CurrentUICulture = New-Object System.Globalization.CultureInfo("en-US")

# ---- Step 1: Ensure module is new enough ----
$minVersion = [version]"3.9.0"
$installed = Get-Module -ListAvailable -Name ExchangeOnlineManagement |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $installed -or $installed.Version -lt $minVersion) {
    Write-Host "Installing/updating ExchangeOnlineManagement module..." -ForegroundColor Yellow
    Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber -Scope CurrentUser
}
Import-Module ExchangeOnlineManagement

# ---- Step 2: Collect inputs ----
do {
    $searchid = Read-Host -Prompt "Enter a search name (letters, numbers, hyphens/underscores only)"
} while ($searchid -match '[^a-zA-Z0-9_-]' -or [string]::IsNullOrWhiteSpace($searchid))

$tempVariable = $searchid + "_Purge"
$adminchoose  = Read-Host -Prompt "Enter your admin UPN (e.g. admin@yourdomain.com)"
$From         = Read-Host -Prompt "Sender email address to search for"
$Subject      = Read-Host -Prompt "Subject line to match (exact text)"

Write-Host ""
$MailboxInput = Read-Host -Prompt "Target mailbox(es), comma-separated -- or leave blank to search ALL mailboxes"
if ([string]::IsNullOrWhiteSpace($MailboxInput)) {
    $ExchangeLocation = "All"
} else {
    $ExchangeLocation = $MailboxInput.Split(",") | ForEach-Object { $_.Trim() }
}

Write-Host ""
Write-Host "PurgeType options: SoftDelete (recoverable by user) or HardDelete (permanent, irreversible)" -ForegroundColor Yellow
$PurgeType = Read-Host -Prompt "Enter PurgeType (SoftDelete/HardDelete)"
if ($PurgeType -notin @("SoftDelete", "HardDelete")) {
    Write-Host "Invalid PurgeType entered. Defaulting to SoftDelete (safer, recoverable)." -ForegroundColor Yellow
    $PurgeType = "SoftDelete"
}

# ---- Step 3: Connect ----
Write-Host ""
Write-Host "Connecting to Exchange Online and Security & Compliance PowerShell..." -ForegroundColor Cyan
Connect-ExchangeOnline -UserPrincipalName $adminchoose
Connect-IPPSSession -UserPrincipalName $adminchoose -EnableSearchOnlySession
Start-Sleep -Seconds 2

# ---- Step 4: Build query and run search ----
$Query = "From:""$From"" AND Subject:""$Subject"""
Write-Host "Query: $Query" -ForegroundColor Green

Write-Host "Creating and starting compliance search '$searchid'..." -ForegroundColor Cyan
New-ComplianceSearch -Name "$searchid" -ExchangeLocation $ExchangeLocation -ContentMatchQuery $Query | Out-Null
Start-ComplianceSearch -Identity "$searchid"

do {
    $searchStatus = (Get-ComplianceSearch -Identity "$searchid").Status
    Write-Host "Compliance search status: $searchStatus"
    Start-Sleep -Seconds 15
} until ($searchStatus -eq "Completed")

$searchResult = Get-ComplianceSearch -Identity "$searchid"
$itemsFound   = $searchResult.Items
Write-Host "Search completed. Items found: $itemsFound" -ForegroundColor Green

if ($itemsFound -eq 0) {
    Write-Host "No matching items found. Nothing to purge." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false
    return
}

# ---- Step 5: Show per-mailbox breakdown ----
$mailboxCounts = @{}
foreach ($entry in ($searchResult.SuccessResults -split ';')) {
    if ($entry -match 'Location:\s*([^,]+),\s*Item count:\s*(\d+)') {
        $loc = $Matches[1].Trim()
        $cnt = [int]$Matches[2]
        if ($cnt -gt 0) { $mailboxCounts[$loc] = $cnt }
    }
}
Write-Host ""
Write-Host "Mailboxes with matches:" -ForegroundColor Cyan
$mailboxCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Host "  $($_.Key): $($_.Value) item(s)" }

$maxPerMailbox = 0
if ($mailboxCounts.Count -gt 0) {
    $maxPerMailbox = ($mailboxCounts.Values | Measure-Object -Maximum).Maximum
}
$roundsNeeded = [Math]::Max(1, [Math]::Ceiling($maxPerMailbox / 10))
if ($roundsNeeded -gt 1) {
    Write-Host ""
    Write-Host "NOTE: at least one mailbox has more than 10 matching items. Purge removes" -ForegroundColor Yellow
    Write-Host "up to 10 items per mailbox per action, so this script will repeat the purge" -ForegroundColor Yellow
    Write-Host "$roundsNeeded time(s) to fully clear it." -ForegroundColor Yellow
}

# ---- Step 6: Confirmation ----
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Yellow
Write-Host " About to purge $itemsFound item(s) using $PurgeType." -ForegroundColor Yellow
if ($PurgeType -eq "HardDelete") {
    Write-Host " HardDelete is IRREVERSIBLE. This cannot be undone." -ForegroundColor Red
}
Write-Host "=====================================================" -ForegroundColor Yellow
$confirm = Read-Host "Type YES to proceed"
if ($confirm -ne "YES") {
    Write-Host "Purge cancelled. No messages were deleted." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false
    return
}

# ---- Step 7: Purge, looping if needed for mailboxes with >10 items ----
$round = 0
$currentSearchName = $searchid
$currentItems = $itemsFound

do {
    $round++
    $purgeActionName = "$($currentSearchName)_Purge"
    Write-Host ""
    Write-Host "Round $round of $roundsNeeded -- creating purge action ($PurgeType)..." -ForegroundColor Cyan
    New-ComplianceSearchAction -SearchName "$currentSearchName" -Purge -PurgeType $PurgeType -Confirm:$false

    do {
        Start-Sleep -Seconds 15
        $action = Get-ComplianceSearchAction -Identity "$purgeActionName"
        Write-Host "  Purge status: $($action.Status)"
    } while ($action.Status -notin @("Completed", "Failed"))

    Write-Host "Round $round finished: $($action.Status)" -ForegroundColor Green
    $action | Format-List Name, Status, Results

    if ($action.Status -eq "Failed") {
        Write-Host "Purge action failed. Most likely cause: your account is missing the" -ForegroundColor Red
        Write-Host "'Search and Purge' role. See PREREQUISITES at the top of this script." -ForegroundColor Red
        Disconnect-ExchangeOnline -Confirm:$false
        return
    }

    if ($round -lt $roundsNeeded) {
        # Re-run the search to catch remaining items in mailboxes over the 10-item cap
        $currentSearchName = "$($searchid)-r$round"
        New-ComplianceSearch -Name "$currentSearchName" -ExchangeLocation $ExchangeLocation -ContentMatchQuery $Query | Out-Null
        Start-ComplianceSearch -Identity "$currentSearchName"
        do {
            Start-Sleep -Seconds 15
            $recheck = Get-ComplianceSearch -Identity "$currentSearchName"
        } while ($recheck.Status -ne "Completed")
        $currentItems = $recheck.Items
        Write-Host "Remaining matching items: $currentItems" -ForegroundColor Yellow
    }

} while ($round -lt $roundsNeeded)

# ---- Step 8: Wrap up ----
Write-Host ""
Write-Host "==== DONE ====" -ForegroundColor Green
Write-Host "Review the 'Results' output above for each round -- 'Failed count: 0' per" -ForegroundColor Green
Write-Host "mailbox is your authoritative confirmation the purge succeeded." -ForegroundColor Green
Write-Host ""
Write-Host "To independently verify:" -ForegroundColor Cyan
Write-Host " - Do NOT use Message Trace -- it never reflects mailbox deletions." -ForegroundColor Cyan
Write-Host " - Wait 30-60 min, then re-run a search-only pass for this same query and" -ForegroundColor Cyan
Write-Host "   confirm Items: 0 (immediate re-checks can show stale/lagging results)." -ForegroundColor Cyan
Write-Host " - Or grant yourself temporary Full Access to a mailbox and check its" -ForegroundColor Cyan
Write-Host "   folders directly, then revoke the access." -ForegroundColor Cyan

Disconnect-ExchangeOnline -Confirm:$false

