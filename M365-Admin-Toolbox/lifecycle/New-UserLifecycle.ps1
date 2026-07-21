<#
.SYNOPSIS
    Provisions a new Microsoft 365 (Entra ID) user via Microsoft Graph, assigns licenses and group
    memberships, and returns a randomly generated temporary password.

.DESCRIPTION
    Connects to Microsoft Graph for the specified tenant, creates a new user with New-MgUser, resolves
    the requested (or tenant-default) license SKU part numbers to SKU IDs via Resolve-LicenseSkuIds,
    assigns those licenses, and adds the user to any explicit groups plus the tenant's default groups.
    If the tenant is configured for hybrid (on-prem AD) sync and -HybridCreateOnPremFirst is specified,
    the script only logs/flags that on-prem creation should happen first via hybrid\New-HybridADUser.ps1
    — it does not attempt to create the same user a second time.

.PARAMETER TenantName
    Name of the tenant as defined in config\tenants.json.

.PARAMETER DisplayName
    Display name for the new user.

.PARAMETER UserPrincipalName
    UPN (sign-in name) for the new user. Accepts either a full UPN (e.g. jdoe@contoso.com) or
    just the local part (e.g. jdoe) - if no '@' is present, the tenant's PrimaryDomain from
    config\tenants.json is appended automatically via Resolve-ToolboxUserPrincipalName, so the
    correct verified domain never has to be typed or picked by hand.

.PARAMETER MailNickname
    Mail nickname (alias) for the new user.

.PARAMETER GivenName
    Optional first name.

.PARAMETER Surname
    Optional last name.

.PARAMETER Department
    Optional department attribute.

.PARAMETER JobTitle
    Optional job title attribute.

.PARAMETER OfficeLocation
    Optional office location attribute.

.PARAMETER UsageLocation
    Optional two-letter usage location (required for license assignment). Defaults to
    $tenant.Cloud.DefaultUsageLocation when not supplied.

.PARAMETER LicenseSkuPartNumbers
    Optional array of license SKU part numbers (e.g. 'ENTERPRISEPACK', 'SPE_E5') to assign. Defaults to
    $tenant.Cloud.DefaultLicenseSkuPartNumbers when not supplied.

.PARAMETER GroupIds
    Optional array of Entra ID group object IDs to add the new user to, in addition to the tenant's
    default groups (Cloud.DefaultUserGroups).

.PARAMETER HybridCreateOnPremFirst
    When set and the tenant is hybrid (OnPrem.Enabled = $true), the script logs a notice that on-prem
    creation should be performed first via hybrid\New-HybridADUser.ps1, rather than also creating the
    user here.

.EXAMPLE
    .\New-UserLifecycle.ps1 -TenantName 'Tenant-Example-Cloud' -DisplayName 'Jane Doe' `
        -UserPrincipalName 'jane.doe@fabrikam.com' -MailNickname 'jane.doe' -GivenName 'Jane' `
        -Surname 'Doe' -Department 'Sales'
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [Parameter(Mandatory)][string]$MailNickname,
    [string]$GivenName,
    [string]$Surname,
    [string]$Department,
    [string]$JobTitle,
    [string]$OfficeLocation,
    [string]$UsageLocation,
    [string[]]$LicenseSkuPartNumbers,
    [string[]]$GroupIds,
    [switch]$HybridCreateOnPremFirst
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Length of the randomly generated temporary password.
$TempPasswordLength = 16
# Number of non-alphanumeric characters required in the temporary password.
$TempPasswordMinNonAlphanumeric = 3
# Character set used to build the random temporary password (avoids ambiguous chars like O/0, I/l/1).
$TempPasswordCharSet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*-_=+'
# Maximum attempts / base delay (seconds) for retryable Graph calls made by this script.
$RetryMaxAttempts = 5
$RetryBaseDelaySeconds = 5

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
. (Join-Path $PSScriptRoot '..\core\Retry.ps1')
. (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')
$tenant = Get-TenantConfig -TenantName $TenantName
. (Join-Path $PSScriptRoot '..\core\Connect-M365.ps1') -TenantName $TenantName -ConnectGraph

$UserPrincipalName = Resolve-ToolboxUserPrincipalName -UserPrincipalName $UserPrincipalName -Tenant $tenant
if (-not $UsageLocation) { $UsageLocation = $tenant.Cloud.DefaultUsageLocation }
if (-not $LicenseSkuPartNumbers) { $LicenseSkuPartNumbers = @($tenant.Cloud.DefaultLicenseSkuPartNumbers) }

if ($HybridCreateOnPremFirst -and $tenant.OnPrem.Enabled) {
    Write-ToolboxLog -TenantName $TenantName -Message 'Hybrid mode selected. Create the on-prem AD account first via hybrid\New-HybridADUser.ps1 (or your AD provisioning workflow) and let sync create the cloud object; skipping cloud user creation here.'
    return
}

function New-ToolboxTempPassword {
    param(
        [int]$Length = 16,
        [int]$MinNonAlphanumeric = 3,
        [string]$CharSet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*-_=+'
    )
    # Cryptographically random selection from the configured character set, independent of
    # System.Web (not guaranteed to be loaded/available on all PowerShell hosts).
    $nonAlphaChars = ($CharSet.ToCharArray() | Where-Object { $_ -notmatch '[A-Za-z0-9]' })
    if (-not $nonAlphaChars -or $nonAlphaChars.Count -eq 0) { $nonAlphaChars = @('!','@','#','$','%') }
    $bytes = [byte[]]::new($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $chars = for ($i = 0; $i -lt $Length; $i++) { $CharSet[$bytes[$i] % $CharSet.Length] }
    # Guarantee the minimum number of non-alphanumeric characters requested.
    for ($i = 0; $i -lt [math]::Min($MinNonAlphanumeric, $Length); $i++) {
        $chars[$i] = $nonAlphaChars[$bytes[$i] % $nonAlphaChars.Count]
    }
    return -join ($chars | Sort-Object { [guid]::NewGuid() })
}

$password = New-ToolboxTempPassword -Length $TempPasswordLength -MinNonAlphanumeric $TempPasswordMinNonAlphanumeric -CharSet $TempPasswordCharSet
$body = @{
    accountEnabled = $true
    displayName = $DisplayName
    userPrincipalName = $UserPrincipalName
    mailNickname = $MailNickname
    givenName = $GivenName
    surname = $Surname
    department = $Department
    jobTitle = $JobTitle
    officeLocation = $OfficeLocation
    usageLocation = $UsageLocation
    passwordProfile = @{
        forceChangePasswordNextSignIn = $true
        password = $password
    }
}

try {
    $newUser = Invoke-WithRetry -TenantName $TenantName -Operation 'New-MgUser' -MaxAttempts $RetryMaxAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
        New-MgUser -BodyParameter $body
    }
    Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Created user $UserPrincipalName"
}
catch {
    Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "Failed to create user $UserPrincipalName : $($_.Exception.Message)"
    throw
}

try {
    $skuIds = Resolve-LicenseSkuIds -SkuPartNumbers $LicenseSkuPartNumbers
    if ($skuIds.Count -gt 0) {
        $add = @()
        foreach ($id in $skuIds) { $add += @{ skuId = $id } }
        Invoke-WithRetry -TenantName $TenantName -Operation 'Set-MgUserLicense' -MaxAttempts $RetryMaxAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
            Set-MgUserLicense -UserId $newUser.Id -BodyParameter @{ addLicenses = $add; removeLicenses = @() }
        } | Out-Null
        Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "Assigned licenses ($($LicenseSkuPartNumbers -join ', ')) to $UserPrincipalName"
    }
    else {
        Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "No license SKUs resolved for $UserPrincipalName; skipping license assignment."
    }
}
catch {
    Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "Failed to assign licenses to $UserPrincipalName : $($_.Exception.Message)"
}

try {
    foreach ($groupId in @($GroupIds + $tenant.Cloud.DefaultUserGroups)) {
        if ([string]::IsNullOrWhiteSpace($groupId)) { continue }
        Invoke-WithRetry -TenantName $TenantName -Operation "New-MgGroupMember:$groupId" -MaxAttempts $RetryMaxAttempts -BaseDelaySeconds $RetryBaseDelaySeconds -ScriptBlock {
            New-MgGroupMember -GroupId $groupId -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($newUser.Id)" }
        } | Out-Null
        Write-ToolboxLog -TenantName $TenantName -Message "Added $UserPrincipalName to group $groupId"
    }
}
catch {
    Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "Failed to add $UserPrincipalName to one or more groups: $($_.Exception.Message)"
}

[pscustomobject]@{
    UserPrincipalName = $UserPrincipalName
    TemporaryPassword = $password
}
