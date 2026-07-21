<#
.SYNOPSIS
    Disables a Microsoft 365 (Entra ID) user's sign-in and optionally performs additional
    offboarding actions (revoke sessions, remove licenses, convert mailbox to shared, disable
    registered devices, flag on-prem AD move).

.DESCRIPTION
    Connects to Microsoft Graph (and Exchange Online, if a mailbox conversion is requested) for the
    specified tenant, looks up the user, and disables sign-in (Update-MgUser -AccountEnabled:$false).
    Each additional destructive action is gated behind its own switch so callers must opt in
    explicitly rather than triggering everything at once:
      - RevokeSessions:            revokes active sign-in sessions (Revoke-MgUserSignInSession)
      - RemoveLicenses:            strips all assigned license SKUs (Set-MgUserLicense)
      - ConvertMailboxToShared:    converts the mailbox to a shared mailbox via Exchange Online
                                    (Set-Mailbox -Type Shared). This is an Exchange Online operation,
                                    not something Graph alone can perform, so -ConnectExchange is
                                    required and only invoked when this switch is used.
      - DisableDevices:            disables the user's registered Entra ID devices
      - MoveOnPremObjectToDisabledOU: for hybrid tenants, logs/flags that the on-prem AD object
                                    should be moved to the configured disabled-users OU via
                                    hybrid\Disable-HybridADUser.ps1 (not performed directly here)

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json.

.PARAMETER UserPrincipalName
    UPN of the user to disable.

.PARAMETER ConvertMailboxToShared
    Converts the user's mailbox to a shared mailbox via Exchange Online (Set-Mailbox -Type Shared).

.PARAMETER RemoveLicenses
    Removes all currently assigned license SKUs from the user.

.PARAMETER DisableDevices
    Disables all Entra ID devices registered to the user.

.PARAMETER RevokeSessions
    Revokes all active sign-in sessions/refresh tokens for the user.

.PARAMETER MoveOnPremObjectToDisabledOU
    For hybrid tenants (OnPrem.Enabled = $true), logs a notice that the on-prem AD object should be
    moved to Cloud.OUPathDisabledUsers via hybrid\Disable-HybridADUser.ps1.

.EXAMPLE
    .\Disable-UserLifecycle.ps1 -TenantName 'Tenant-Example-Cloud' -UserPrincipalName 'jane.doe@fabrikam.com' `
        -RevokeSessions -RemoveLicenses -ConvertMailboxToShared

.EXAMPLE
    .\Disable-UserLifecycle.ps1 -TenantName 'Tenant-Example-NA' -UserPrincipalName 'jane.doe@contoso.com' `
        -RevokeSessions -MoveOnPremObjectToDisabledOU
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [switch]$ConvertMailboxToShared,
    [switch]$RemoveLicenses,
    [switch]$DisableDevices,
    [switch]$RevokeSessions,
    [switch]$MoveOnPremObjectToDisabledOU
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Maximum attempts / base delay (seconds) for retryable Graph/Exchange calls made by this script.
$RetryMaxAttempts = 5
$RetryBaseDelaySeconds = 5

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
$tenant = Get-TenantConfig -TenantName $TenantName
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectGraph -ConnectExchange:$ConvertMailboxToShared.IsPresent

try {
    $user = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'"
    if (-not $user) { throw "User not found: $UserPrincipalName" }
}
catch {
    Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "Failed to look up user $UserPrincipalName : $($_.Exception.Message)"
    throw
}

try {
    Invoke-WithRetry -TenantName $TenantName -Operation 'Update-MgUser:Disable' -MaxAttempts $RetryMaxAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
        Update-MgUser -UserId $user.Id -AccountEnabled:$false
    } | Out-Null
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Disabled sign-in for $UserPrincipalName"
}
catch {
    Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "Failed to disable sign-in for $UserPrincipalName : $($_.Exception.Message)"
    throw
}

if ($RevokeSessions) {
    try {
        Invoke-WithRetry -TenantName $TenantName -Operation 'Revoke-MgUserSignInSession' -MaxAttempts $RetryMaxAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
            Revoke-MgUserSignInSession -UserId $user.Id
        } | Out-Null
        Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Revoked sessions for $UserPrincipalName"
    }
    catch {
        Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "Failed to revoke sessions for $UserPrincipalName : $($_.Exception.Message)"
    }
}

if ($RemoveLicenses) {
    try {
        $full = Get-MgUser -UserId $user.Id -Property AssignedLicenses
        $remove = @($full.AssignedLicenses | ForEach-Object { $_.SkuId })
        if ($remove.Count -gt 0) {
            Invoke-WithRetry -TenantName $TenantName -Operation 'Set-MgUserLicense:Remove' -MaxAttempts $RetryMaxAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
                Set-MgUserLicense -UserId $user.Id -BodyParameter @{ addLicenses = @(); removeLicenses = $remove }
            } | Out-Null
            Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Removed licenses for $UserPrincipalName"
        }
        else {
            Write-ToolboxLog -TenantName $TenantName -Level 'INFO' -Message "No assigned licenses found for $UserPrincipalName; nothing to remove."
        }
    }
    catch {
        Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "Failed to remove licenses for $UserPrincipalName : $($_.Exception.Message)"
    }
}

if ($ConvertMailboxToShared) {
    try {
        # Exchange Online operation - Graph alone cannot convert a mailbox to shared.
        Invoke-WithRetry -TenantName $TenantName -Operation 'Set-Mailbox:Shared' -MaxAttempts $RetryMaxAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
            Set-Mailbox -Identity $UserPrincipalName -Type Shared
        } | Out-Null
        Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Converted mailbox to shared for $UserPrincipalName"
    }
    catch {
        Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "Failed to convert mailbox to shared for $UserPrincipalName : $($_.Exception.Message)"
    }
}

if ($DisableDevices) {
    try {
        $devices = Get-MgUserRegisteredDevice -UserId $user.Id -All
        foreach ($device in $devices) {
            if ($device.Id) {
                Invoke-WithRetry -TenantName $TenantName -Operation "Update-MgDevice:$($device.Id)" -MaxAttempts $RetryMaxAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
                    Update-MgDevice -DeviceId $device.Id -AccountEnabled:$false
                } | Out-Null
            }
        }
        Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Disabled registered devices for $UserPrincipalName"
    }
    catch {
        Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "Failed to disable one or more devices for $UserPrincipalName : $($_.Exception.Message)"
    }
}

if ($MoveOnPremObjectToDisabledOU -and $tenant.OnPrem.Enabled) {
    Write-ToolboxLog -TenantName $TenantName -Message 'On-prem move requested. Move the on-prem AD object to the configured OUPathDisabledUsers via hybrid\Disable-HybridADUser.ps1 (or your AD provisioning workflow).'
}
elseif ($MoveOnPremObjectToDisabledOU -and -not $tenant.OnPrem.Enabled) {
    Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "MoveOnPremObjectToDisabledOU was requested but tenant '$TenantName' is not configured for on-prem (OnPrem.Enabled = false); skipping."
}
