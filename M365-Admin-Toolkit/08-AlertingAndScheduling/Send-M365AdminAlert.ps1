<#
.SYNOPSIS
    Shared notification helper - sends an alert via email (Graph, app-only)
    and/or a Teams channel, so every scheduled check in this toolkit uses
    one consistent alerting path instead of each script rolling its own.

.DESCRIPTION
    Two channels, either or both:
      - Email: sent via Graph (Send-MgUserMail) FROM a mailbox you specify
        (a shared mailbox like it-alerts@yourdomain.com is the right
        choice - not a personal account). Requires Mail.Send application
        permission on the app registration.
      - Teams: posted to a webhook URL as an adaptive card.

    IMPORTANT re: Teams webhooks - classic "Incoming Webhook" connectors
    are being retired by Microsoft in favor of Workflows (Power Automate).
    If your tenant still has a working Incoming Webhook connector URL,
    this script's simple payload will work as-is. If Incoming Webhooks
    have been retired for your tenant, create a Power Automate flow using
    the "When a Teams webhook request is received" trigger instead - it
    accepts an HTTP POST the same way, so this script still works, you
    just point $TeamsWebhookUrl at the flow's HTTP trigger URL instead of
    a classic connector URL. Verify current status in your tenant rather
    than assuming either path - this has been a moving target.

.PARAMETER Subject
    Short subject line for the alert - used as the email subject (prefixed
    with [Severity]) and the Teams card title.

.PARAMETER Body
    Main alert content - plain text or simple HTML for email; also used
    as the Teams card text (newlines are converted to <br>).

.PARAMETER Severity
    One of "Info", "Warning", "Critical". Drives the color/styling of the
    email and Teams card. Defaults to "Info".

.PARAMETER DetailsUrl
    Optional link (e.g. to an exported CSV/report if hosted somewhere)
    added as a clickable link/action on both channels.

.EXAMPLE
    . .\08-AlertingAndScheduling\Send-M365AdminAlert.ps1
    Send-M365AdminAlert -Subject "Mailbox over quota" -Body "5 mailboxes over 90%" -Severity Warning

.NOTES
    Dot-source this and call Send-M365AdminAlert from any script:
        . .\08-AlertingAndScheduling\Send-M365AdminAlert.ps1
        Send-M365AdminAlert -Subject "..." -Body "..." -Severity Warning
#>

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$Global:AlertConfig = @{
    # Master on/off switch for the email channel.
    EmailEnabled       = $true

    # Mailbox the alert is sent FROM - must be a real mailbox (ideally a
    # shared mailbox like it-alerts@yourdomain.com) that the app registration
    # has Mail.Send rights to send-as. Not a personal account.
    EmailFromMailbox   = "it-alerts@yourdomain.com"

    # Recipient address(es) that receive alerts - array, add more as needed.
    EmailToRecipients  = @("admin@yourdomain.com")

    # Optional CC recipient(s) - leave as empty array if not needed.
    EmailCcRecipients  = @()

    # Master on/off switch for the Teams channel.
    TeamsEnabled       = $true

    # Teams Incoming Webhook URL or Power Automate HTTP trigger URL (see
    # the Teams webhook caveat above) - leave the placeholder to skip
    # posting to Teams until you set a real URL.
    TeamsWebhookUrl    = "<paste-your-webhook-or-power-automate-http-trigger-url-here>"
}

function Send-M365AdminAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,          # plain text or simple HTML for email; also used for Teams card text
        [ValidateSet("Info","Warning","Critical")]
        [string]$Severity = "Info",
        [string]$DetailsUrl                            # optional - e.g. link to the exported CSV/report if hosted somewhere
    )

    $color = switch ($Severity) {
        "Critical" { "attention" }   # Teams adaptive card style names
        "Warning"  { "warning" }
        default    { "good" }
    }

    if ($Global:AlertConfig.EmailEnabled) {
        try {
            $htmlBody = "<p><b>[$Severity]</b> $Subject</p><pre>$Body</pre>"
            if ($DetailsUrl) { $htmlBody += "<p><a href='$DetailsUrl'>View details</a></p>" }

            $message = @{
                Message = @{
                    Subject = "[$Severity] $Subject"
                    Body = @{ ContentType = "HTML"; Content = $htmlBody }
                    ToRecipients = $Global:AlertConfig.EmailToRecipients | ForEach-Object { @{ EmailAddress = @{ Address = $_ } } }
                    CcRecipients = $Global:AlertConfig.EmailCcRecipients | ForEach-Object { @{ EmailAddress = @{ Address = $_ } } }
                }
                SaveToSentItems = $true
            }
            Send-MgUserMail -UserId $Global:AlertConfig.EmailFromMailbox -BodyParameter $message
            Write-Host "[Alert] Email sent to $($Global:AlertConfig.EmailToRecipients -join ', ')" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to send alert email: $_"
        }
    }

    if ($Global:AlertConfig.TeamsEnabled -and $Global:AlertConfig.TeamsWebhookUrl -notmatch "^<paste") {
        try {
            $card = @{
                "@type"    = "MessageCard"
                "@context" = "http://schema.org/extensions"
                themeColor = switch ($Severity) { "Critical" { "FF0000" } "Warning" { "FFA500" } default { "00A0E4" } }
                title      = "[$Severity] $Subject"
                text       = $Body -replace "`n", "<br>"
            }
            if ($DetailsUrl) {
                $card.potentialAction = @(@{ "@type" = "OpenUri"; name = "View details"; targets = @(@{ os = "default"; uri = $DetailsUrl }) })
            }
            Invoke-RestMethod -Uri $Global:AlertConfig.TeamsWebhookUrl -Method Post -Body ($card | ConvertTo-Json -Depth 5) -ContentType "application/json"
            Write-Host "[Alert] Teams notification sent." -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to send Teams alert: $_"
        }
    }
}
