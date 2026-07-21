<#
.SYNOPSIS
    Registers the two scheduled checks (app secret expiry, mailbox
    storage) as Windows Scheduled Tasks running under pwsh.exe.

.DESCRIPTION
    Run this once on whatever host will run the automation (a management
    server or the DC, consistent with where your other scheduled scripts
    already live). Creates two tasks:
      - "M365 - App Secret Expiry Check"  (default: daily, 6 AM)
      - "M365 - Mailbox Storage Check"    (default: daily, 6:15 AM)

.PARAMETER RunAsAccount
    Domain\username (or .\username for a local account) of the service
    account the scheduled tasks will run as. You'll be prompted for its
    password. Defaults to a placeholder - override for your environment.

.PARAMETER PwshPath
    Full path to pwsh.exe (PowerShell 7) on the host that will run the
    tasks. Defaults to the standard PS7 install location.

.EXAMPLE
    .\Register-ScheduledTasks.ps1
    Run elevated, prompts for the default service account's password,
    registers both tasks using the default schedule in $Tasks below.

.EXAMPLE
    .\Register-ScheduledTasks.ps1 -RunAsAccount "CONTOSO\svc-m365automation" -WhatIf
    Preview what would be registered without actually creating the tasks.

.NOTES
    Must be run elevated (Administrator) - Register-ScheduledTask requires
    it. The task's "Run As" account needs local rights to run pwsh and
    network access to reach Graph/EXO - use a dedicated service account,
    not a personal admin account, consistent with how you've set up other
    scheduled automation.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RunAsAccount = "YOURDOMAIN\svc-m365automation",
    [string]$PwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$Tasks = @(
    @{
        # Task Scheduler display name for the app secret expiry check.
        Name        = "M365 - App Secret Expiry Check"
        # Script this task runs - lives alongside this file in 08-AlertingAndScheduling.
        ScriptPath  = "$PSScriptRoot\Invoke-ScheduledAppSecretExpiryCheck.ps1"
        # Daily run time (24h HH:mm) for this task.
        TriggerTime = "06:00"
        # Trigger frequency - only "Daily" is currently implemented below.
        Frequency   = "Daily"
    },
    @{
        # Task Scheduler display name for the mailbox storage check.
        Name        = "M365 - Mailbox Storage Check"
        # Script this task runs - lives alongside this file in 08-AlertingAndScheduling.
        ScriptPath  = "$PSScriptRoot\Invoke-ScheduledMailboxStorageCheck.ps1"
        # Daily run time (24h HH:mm) for this task.
        TriggerTime = "06:15"
        # Trigger frequency - only "Daily" is currently implemented below.
        Frequency   = "Daily"
    }
)

if (-not (Test-Path $PwshPath)) {
    Write-Warning "PowerShell 7 not found at $PwshPath - update -PwshPath or install PS7 on this host first."
}

$cred = Get-Credential -UserName $RunAsAccount -Message "Enter password for the service account that will run these tasks"

foreach ($t in $Tasks) {
    $action = New-ScheduledTaskAction -Execute $PwshPath -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$($t.ScriptPath)`""
    $trigger = New-ScheduledTaskTrigger -Daily -At $t.TriggerTime
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    if ($PSCmdlet.ShouldProcess($t.Name, "Register scheduled task")) {
        Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $trigger -Settings $settings `
            -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Force
        Write-Host "[OK] Registered: $($t.Name) - daily at $($t.TriggerTime)" -ForegroundColor Green
    }
}

Write-Host "`nDone. Verify in Task Scheduler, and run each task manually once (Right-click > Run) to confirm auth/permissions work before trusting the schedule." -ForegroundColor Cyan
