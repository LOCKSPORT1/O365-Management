<#
.SYNOPSIS
    Interactive Windows Autopilot environment builder for Microsoft Intune.

.DESCRIPTION
    Interview-style wizard that:
      1. Connects to Microsoft Graph
      2. Enumerates all Intune applications as a numbered menu
      3. Asks which departments/personas you need
      4. Creates dynamic Entra ID device groups keyed on Autopilot Group Tags
      5. Creates an Autopilot deployment profile per department (Entra join
         or Hybrid Azure AD join)
      6. For hybrid: creates and assigns a Domain Join configuration profile
      7. Assigns your selected apps (Required / Available) to each group

    Designed to be tenant-agnostic. All environment-specific values live in
    the Configuration region or are collected interactively.

.NOTES
    Version : 1.0
    Requires: Microsoft.Graph.Authentication module
    Scopes  : DeviceManagementServiceConfig.ReadWrite.All
              DeviceManagementApps.ReadWrite.All
              DeviceManagementConfiguration.ReadWrite.All
              Group.ReadWrite.All

    Run with -WhatIfMode to preview every change without creating anything.

.EXAMPLE
    .\Invoke-AutopilotBuilder.ps1

.EXAMPLE
    .\Invoke-AutopilotBuilder.ps1 -WhatIfMode
#>

[CmdletBinding()]
param(
    # Preview mode - nothing is created, all payloads are displayed instead
    [switch]$WhatIfMode
)

#region Configuration
# ============================================================================
# Adjust these defaults for your environment. Everything else is interactive.
# ============================================================================

$Config = @{
    # Prefix applied to all created objects (groups, profiles)
    NamingPrefix          = 'AP'

    # Group name pattern. {prefix} and {dept} are replaced at runtime.
    GroupNameTemplate     = '{prefix}-{dept}-Devices'

    # Deployment profile name pattern
    # NOTE: underscores, not hyphens - Autopilot profile names reject '-'
    ProfileNameTemplate   = '{prefix}_{dept}_DeploymentProfile'

    # Device name template. {tag} is replaced with the department group tag.
    # %RAND:x% and %SERIAL% are Autopilot native macros. Max 15 characters.
    DeviceNameTemplate    = '{tag}-%RAND:5%'

    # OOBE defaults applied to every deployment profile
    OOBE = @{
        HidePrivacySettings       = $true
        HideEULA                  = $true
        UserType                  = 'standard'     # 'standard' or 'administrator'
        DeviceUsageType           = 'singleUser'   # 'singleUser' or 'shared'
        SkipKeyboardSelectionPage = $true
    }

    # Locale / language for deployment profiles ('os-default' or e.g. 'en-US')
    ProfileLanguage       = 'os-default'

    # Enable pre-provisioning (White Glove) support on profiles
    EnablePreProvisioning = $true

    # Graph environment
    GraphScopes = @(
        'DeviceManagementServiceConfig.ReadWrite.All'
        'DeviceManagementApps.ReadWrite.All'
        'DeviceManagementConfiguration.ReadWrite.All'
        'Group.ReadWrite.All'
    )
}
# ============================================================================
#endregion Configuration

#region Helper Functions

function Write-Banner {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}

function Write-Step {
    param([string]$Text)
    Write-Host "`n>> $Text" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Text)
    Write-Host "   [OK] $Text" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Text)
    Write-Host "   [WHATIF] $Text" -ForegroundColor Magenta
}

function Read-Answer {
    param(
        [string]$Prompt,
        [string]$Default = ''
    )
    if ($Default) {
        $raw = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        return $raw.Trim()
    }
    do {
        $raw = Read-Host $Prompt
    } while ([string]::IsNullOrWhiteSpace($raw))
    return $raw.Trim()
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $true
    )
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $raw = Read-Host "$Prompt ($hint)"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return $raw.Trim().ToLower().StartsWith('y')
}

function ConvertTo-SelectionIndexes {
    <#
        Parses menu selections like "1,3,5-8" into an array of integers.
        Returns $null for blank input (meaning: none selected).
    #>
    param(
        [string]$InputText,
        [int]$Max
    )
    if ([string]::IsNullOrWhiteSpace($InputText)) { return @() }

    $indexes = @()
    foreach ($chunk in ($InputText -split ',')) {
        $part = $chunk.Trim()
        if ($part -match '^(\d+)\s*-\s*(\d+)$') {
            $start = [int]$Matches[1]; $end = [int]$Matches[2]
            if ($start -gt $end) { $start, $end = $end, $start }
            foreach ($i in $start..$end) { $indexes += $i }
        }
        elseif ($part -match '^\d+$') {
            $indexes += [int]$part
        }
        else {
            Write-Host "   Ignoring unrecognized selection: '$part'" -ForegroundColor DarkYellow
        }
    }
    return @($indexes | Sort-Object -Unique | Where-Object { $_ -ge 1 -and $_ -le $Max })
}

function ConvertTo-GroupTag {
    <#
        Converts a department name into a short, clean group tag.
        "Advance Steel Engineering" -> "ADVANCESTEELENG" is too long,
        so we take the first 10 alphanumeric characters uppercased,
        then let the user override interactively.
    #>
    param([string]$DepartmentName)
    $clean = ($DepartmentName -replace '[^A-Za-z0-9]', '').ToUpper()
    if ($clean.Length -gt 10) { $clean = $clean.Substring(0, 10) }
    return $clean
}

function Invoke-GraphCall {
    <#
        Wrapper around Invoke-MgGraphRequest with WhatIf support and
        consistent error handling.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Body,
        [string]$Description = ''
    )

    if ($WhatIfMode -and $Method -ne 'GET') {
        Write-Skip "$Method $Uri"
        if ($Body) {
            Write-Host ($Body | ConvertTo-Json -Depth 10) -ForegroundColor DarkGray
        }
        # Return a fake object so downstream steps can continue in preview
        return [pscustomobject]@{ id = "whatif-$([guid]::NewGuid().ToString().Substring(0,8))" }
    }

    try {
        $params = @{ Method = $Method; Uri = $Uri; ErrorAction = 'Stop' }
        if ($Body) {
            $params['Body']        = ($Body | ConvertTo-Json -Depth 10)
            $params['ContentType'] = 'application/json'
        }
        return Invoke-MgGraphRequest @params
    }
    catch {
        Write-Host "   [ERROR] $Description failed: $($_.Exception.Message)" -ForegroundColor Red
        if ($Body) {
            Write-Host '   Request payload was:' -ForegroundColor DarkGray
            Write-Host ($Body | ConvertTo-Json -Depth 10) -ForegroundColor DarkGray
        }
        throw
    }
}

#endregion Helper Functions

#region Graph Connection

function Connect-BuilderGraph {
    Write-Step 'Connecting to Microsoft Graph'

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Host '   Microsoft.Graph.Authentication module not found. Installing...' -ForegroundColor Yellow
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $ctx = Get-MgContext
    $needed = $Config.GraphScopes
    if (-not $ctx -or (@($needed | Where-Object { $_ -notin $ctx.Scopes }).Count -gt 0)) {
        Connect-MgGraph -Scopes $needed -NoWelcome -ErrorAction Stop
    }

    $ctx = Get-MgContext
    Write-Ok "Connected to tenant $($ctx.TenantId) as $($ctx.Account)"
}

#endregion Graph Connection

#region Intune App Functions

function Get-IntuneAppInventory {
    <#
        Returns all assignable Intune apps as an ordered, numbered list.
        Filters out built-in / managed store noise where possible.
    #>
    Write-Step 'Retrieving Intune application inventory'

    $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=(isAssigned eq true or isAssigned eq false)&`$orderby=displayName&`$top=200"
    $apps = @()

    do {
        $page = Invoke-GraphCall -Method GET -Uri $uri -Description 'App inventory query'
        foreach ($app in $page.value) {
            $type = ($app.'@odata.type' -replace '#microsoft.graph.', '')
            # Skip framework/built-in noise
            if ($type -in @('androidManagedStoreWebApp')) { continue }
            $apps += [pscustomobject]@{
                Id          = $app.id
                DisplayName = $app.displayName
                Type        = $type
                Publisher   = $app.publisher
            }
        }
        $uri = $page.'@odata.nextLink'
    } while ($uri)

    Write-Ok "Found $($apps.Count) applications"
    return ,$apps
}

function Show-AppMenu {
    param([object[]]$Apps)
    Write-Host ''
    Write-Host ('{0,4}  {1,-50} {2}' -f '#', 'Application', 'Type') -ForegroundColor Cyan
    Write-Host ('-' * 90) -ForegroundColor DarkGray
    for ($i = 0; $i -lt $Apps.Count; $i++) {
        $name = $Apps[$i].DisplayName
        if ($name.Length -gt 48) { $name = $name.Substring(0, 45) + '...' }
        Write-Host ('{0,4}  {1,-50} {2}' -f ($i + 1), $name, $Apps[$i].Type)
    }
    Write-Host ''
}

function Set-AppAssignment {
    <#
        Assigns an app to a group with the given intent, preserving any
        existing assignments on the app.
    #>
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][ValidateSet('required', 'available')]
        [string]$Intent
    )

    # Pull existing assignments so we append rather than overwrite
    $existing = @()
    if (-not $WhatIfMode) {
        $current = Invoke-GraphCall -Method GET `
            -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments" `
            -Description "Read assignments for $AppName"
        foreach ($a in $current.value) {
            # Skip if this group is already targeted
            if ($a.target.groupId -eq $GroupId) {
                Write-Ok "$AppName already assigned to this group - skipping"
                return
            }
            $existing += @{
                '@odata.type' = '#microsoft.graph.mobileAppAssignment'
                intent        = $a.intent
                target        = $a.target
            }
        }
    }

    $newAssignment = @{
        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
        intent        = $Intent
        target        = @{
            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
            groupId       = $GroupId
        }
    }

    $body = @{ mobileAppAssignments = @($existing + $newAssignment) }

    Invoke-GraphCall -Method POST `
        -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assign" `
        -Body $body `
        -Description "Assign $AppName" | Out-Null

    Write-Ok "$AppName -> $Intent"
}

#endregion Intune App Functions

#region Group Functions

function New-AutopilotDeptGroup {
    <#
        Creates a dynamic Entra ID device group whose membership rule keys
        on the Autopilot Group Tag (OrderID). Any Autopilot device imported
        with this tag lands in the group automatically.
    #>
    param(
        [Parameter(Mandatory)][string]$Department,
        [Parameter(Mandatory)][string]$GroupTag
    )

    $groupName = $Config.GroupNameTemplate.Replace('{prefix}', $Config.NamingPrefix).Replace('{dept}', $Department)
    $mailNick  = ($groupName -replace '[^A-Za-z0-9]', '')
    $rule      = "(device.devicePhysicalIds -any (_ -eq `"[OrderID]:$GroupTag`"))"

    # Idempotency: reuse existing group with the same name
    if (-not $WhatIfMode) {
        $escaped = $groupName -replace "'", "''"
        $lookup = Invoke-GraphCall -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$escaped'" `
            -Description "Group lookup for $groupName"
        if ($lookup.value.Count -gt 0) {
            Write-Ok "Group '$groupName' already exists - reusing"
            return $lookup.value[0]
        }
    }

    $body = @{
        displayName                   = $groupName
        description                   = "Autopilot devices for $Department (Group Tag: $GroupTag). Created by Invoke-AutopilotBuilder."
        mailEnabled                   = $false
        mailNickname                  = $mailNick
        securityEnabled               = $true
        groupTypes                    = @('DynamicMembership')
        membershipRule                = $rule
        membershipRuleProcessingState = 'On'
    }

    $group = Invoke-GraphCall -Method POST `
        -Uri 'https://graph.microsoft.com/v1.0/groups' `
        -Body $body `
        -Description "Create group $groupName"

    Write-Ok "Created dynamic group '$groupName' (rule: OrderID = $GroupTag)"
    return $group
}

#endregion Group Functions

#region Autopilot Profile Functions

function New-AutopilotProfile {
    <#
        Creates a Windows Autopilot deployment profile.
        JoinType 'entra'  -> azureADWindowsAutopilotDeploymentProfile
        JoinType 'hybrid' -> activeDirectoryWindowsAutopilotDeploymentProfile
    #>
    param(
        [Parameter(Mandatory)][string]$Department,
        [Parameter(Mandatory)][string]$GroupTag,
        [Parameter(Mandatory)][ValidateSet('entra', 'hybrid')]
        [string]$JoinType
    )

    $profileName = $Config.ProfileNameTemplate.Replace('{prefix}', $Config.NamingPrefix).Replace('{dept}', $Department)
    $deviceName  = $Config.DeviceNameTemplate.Replace('{tag}', $GroupTag)

    # Length check only matters for Entra join (hybrid naming comes from the
    # Domain Join profile). Measure the RENDERED name: %RAND:n% -> n chars.
    if ($JoinType -eq 'entra') {
        $rendered = [regex]::Replace($deviceName, '%RAND:(\d+)%', { param($m) 'X' * [int]$m.Groups[1].Value })
        if ($rendered.Length -gt 15) {
            $literalLen = $rendered.Length - $GroupTag.Length
            $maxTagLen  = [Math]::Max(1, 15 - $literalLen)
            $shortTag   = $GroupTag.Substring(0, [Math]::Min($maxTagLen, $GroupTag.Length))
            Write-Host "   [WARN] Rendered device name '$rendered' exceeds 15 chars; using tag '$shortTag'." -ForegroundColor DarkYellow
            $deviceName = $Config.DeviceNameTemplate.Replace('{tag}', $shortTag)
        }
    }

    $odataType = if ($JoinType -eq 'hybrid') {
        '#microsoft.graph.activeDirectoryWindowsAutopilotDeploymentProfile'
    } else {
        '#microsoft.graph.azureADWindowsAutopilotDeploymentProfile'
    }

    # ---- Idempotency + template discovery ------------------------------------
    # One GET serves two purposes:
    #   1. If a profile with this name already exists, reuse it.
    #   2. Cache any existing profile of the same join type as a CLONE TEMPLATE
    #      (e.g., one created manually in the portal) - a payload the tenant's
    #      own API version is guaranteed to accept.
    if (-not $WhatIfMode) {
        if (-not $script:ProfileCache) {
            $script:ProfileCache = @()
            $listUri = 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles'
            do {
                $pg = Invoke-GraphCall -Method GET -Uri $listUri -Description 'List existing deployment profiles'
                $script:ProfileCache += @($pg.value)
                $listUri = $pg.'@odata.nextLink'
            } while ($listUri)
        }
        $existing = $script:ProfileCache |
            Where-Object { $_.displayName -and ($_.displayName.Trim() -ieq $profileName) } |
            Select-Object -First 1
        if ($existing) {
            Write-Ok "Deployment profile '$profileName' already exists - reusing"
            return $existing
        }
        $template = $script:ProfileCache |
            Where-Object { $_.'@odata.type' -eq $odataType } |
            Sort-Object { $_.createdDateTime } -Descending |
            Select-Object -First 1
        if ($template) {
            Write-Host "   Cloning existing profile '$($template.displayName)' as schema template..." -ForegroundColor DarkGray

            # GET responses include BOTH legacy and current schema synonyms;
            # a POST must contain only ONE set. Build both variants.
            $legacyProps = @('language', 'enableWhiteGlove', 'extractHardwareHash', 'outOfBoxExperienceSettings')
            $newProps    = @('locale', 'preprovisioningAllowed', 'hardwareHashExtractionEnabled', 'outOfBoxExperienceSetting')
            $skipProps   = @('id', 'createdDateTime', 'lastModifiedDateTime', 'roleScopeTagIds', 'managementServiceAppId')

            $base = @{}
            foreach ($key in $template.Keys) {
                if ($key -in $skipProps) { continue }
                if ($null -eq $template[$key]) { continue }
                $base[$key] = $template[$key]
            }
            $base['displayName'] = $profileName
            $base['description'] = "Autopilot deployment profile for $Department. Created by Invoke-AutopilotBuilder."
            if ($JoinType -eq 'entra') { $base['deviceNameTemplate'] = $deviceName }
            elseif ($base.ContainsKey('deviceNameTemplate') -and [string]::IsNullOrEmpty($base['deviceNameTemplate'])) {
                $base.Remove('deviceNameTemplate')
            }

            $variants = @()
            foreach ($drop in @($legacyProps, $newProps)) {
                $v = @{}
                foreach ($k in $base.Keys) { if ($k -notin $drop) { $v[$k] = $base[$k] } }
                $variants += ,$v
            }

            foreach ($clone in $variants) {
                try {
                    $profile = Invoke-GraphCall -Method POST `
                        -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles' `
                        -Body $clone `
                        -Description "Create deployment profile $profileName (cloned from template)"
                    Write-Ok "Created deployment profile '$profileName' (cloned from '$($template.displayName)')"
                    $script:ProfileCache += $profile
                    return $profile
                }
                catch {
                    Write-Host '   Clone variant rejected - trying next...' -ForegroundColor DarkYellow
                }
            }
            Write-Host '   All clone variants failed - falling back to built-in payloads...' -ForegroundColor DarkYellow
        }
    }
    # ---------------------------------------------------------------------------

    # Pre-provisioning (White Glove) is NOT supported for hybrid join profiles
    # and causes the service to reject the request with a generic 400.
    $preProv = if ($JoinType -eq 'hybrid') { $false } else { [bool]$Config.EnablePreProvisioning }

    # --- Current (2024+) schema ---------------------------------------------
    $bodyCurrent = @{
        '@odata.type'                 = $odataType
        displayName                   = $profileName
        description                   = "Autopilot deployment profile for $Department. Created by Invoke-AutopilotBuilder."
        locale                        = $Config.ProfileLanguage
        preprovisioningAllowed        = $preProv
        hardwareHashExtractionEnabled = $false
        deviceType                    = 'windowsPc'
        roleScopeTagIds               = @('0')
        outOfBoxExperienceSetting     = @{
            privacySettingsHidden        = [bool]$Config.OOBE.HidePrivacySettings
            eulaHidden                   = [bool]$Config.OOBE.HideEULA
            userType                     = $Config.OOBE.UserType
            deviceUsageType              = $Config.OOBE.DeviceUsageType
            keyboardSelectionPageSkipped = [bool]$Config.OOBE.SkipKeyboardSelectionPage
            escapeLinkHidden             = $true
        }
    }

    # --- Legacy schema (fallback for older tenant API versions) --------------
    $bodyLegacy = @{
        '@odata.type'              = $odataType
        displayName                = $profileName
        description                = $bodyCurrent.description
        language                   = $Config.ProfileLanguage
        enableWhiteGlove           = $preProv
        extractHardwareHash        = $false
        deviceType                 = 'windowsPc'
        roleScopeTagIds            = @('0')
        outOfBoxExperienceSettings = @{
            hidePrivacySettings       = [bool]$Config.OOBE.HidePrivacySettings
            hideEULA                  = [bool]$Config.OOBE.HideEULA
            userType                  = $Config.OOBE.UserType
            deviceUsageType           = $Config.OOBE.DeviceUsageType
            skipKeyboardSelectionPage = [bool]$Config.OOBE.SkipKeyboardSelectionPage
            hideEscapeLink            = $true
        }
    }

    foreach ($body in @($bodyCurrent, $bodyLegacy)) {
        if ($JoinType -eq 'hybrid') {
            # NOTE: deviceNameTemplate is NOT valid on hybrid profiles. Naming
            # comes from the Domain Join configuration profile instead.
            # This flag requires DC line-of-sight during OOBE when $false:
            $body['hybridAzureADJoinSkipConnectivityCheck'] = $false
        }
        else {
            $body['deviceNameTemplate'] = $deviceName
        }
    }

    $profile = $null
    try {
        $profile = Invoke-GraphCall -Method POST `
            -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles' `
            -Body $bodyCurrent `
            -Description "Create deployment profile $profileName (current schema)"
    }
    catch {
        Write-Host '   Current schema rejected - retrying with legacy schema...' -ForegroundColor DarkYellow
        $profile = Invoke-GraphCall -Method POST `
            -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles' `
            -Body $bodyLegacy `
            -Description "Create deployment profile $profileName (legacy schema)"
    }

    if ($JoinType -eq 'hybrid') {
        Write-Ok "Created deployment profile '$profileName' (hybrid join; device naming set by Domain Join profile)"
    } else {
        Write-Ok "Created deployment profile '$profileName' (entra join, device name: $deviceName)"
    }
    return $profile
}

function Set-AutopilotProfileAssignment {
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [Parameter(Mandatory)][string]$GroupId
    )

    if (-not $WhatIfMode) {
        $current = Invoke-GraphCall -Method GET `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/$ProfileId/assignments" `
            -Description 'Read profile assignments'
        foreach ($a in $current.value) {
            if ($a.target.groupId -eq $GroupId) {
                Write-Ok 'Deployment profile already assigned to this group - skipping'
                return
            }
        }
    }

    $body = @{
        target = @{
            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
            groupId       = $GroupId
        }
    }

    Invoke-GraphCall -Method POST `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/$ProfileId/assignments" `
        -Body $body `
        -Description 'Assign deployment profile' | Out-Null

    Write-Ok 'Deployment profile assigned to group'
}

function New-DomainJoinProfile {
    <#
        Hybrid-only: creates the Domain Join device configuration profile
        that tells the Intune Connector for AD where to create the computer
        object, then assigns it to the department group.
    #>
    param(
        [Parameter(Mandatory)][string]$Department,
        [Parameter(Mandatory)][string]$GroupTag,
        [Parameter(Mandatory)][string]$DomainFqdn,
        [Parameter(Mandatory)][string]$OuDistinguishedName,
        [Parameter(Mandatory)][string]$GroupId
    )

    $profileName = "$($Config.NamingPrefix)_$($Department)_DomainJoin"
    $prefix      = $GroupTag.Substring(0, [Math]::Min(7, $GroupTag.Length))

    # Idempotency: reuse an existing domain join profile with the same name
    if (-not $WhatIfMode) {
        $listUri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?`$select=id,displayName"
        do {
            $pg = Invoke-GraphCall -Method GET -Uri $listUri -Description 'List device configurations'
            $match = $pg.value | Where-Object { $_.displayName -eq $profileName } | Select-Object -First 1
            if ($match) {
                Write-Ok "Domain join profile '$profileName' already exists - reusing"
                return $match
            }
            $listUri = $pg.'@odata.nextLink'
        } while ($listUri)
    }

    $body = @{
        '@odata.type'                    = '#microsoft.graph.windowsDomainJoinConfiguration'
        displayName                      = $profileName
        description                      = "Hybrid domain join settings for $Department. Created by Invoke-AutopilotBuilder."
        computerNameStaticPrefix         = $prefix
        computerNameSuffixRandomCharCount = [Math]::Min(15 - $prefix.Length, 8)
        activeDirectoryDomainName        = $DomainFqdn
        organizationalUnit               = $OuDistinguishedName
    }

    $djProfile = Invoke-GraphCall -Method POST `
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations' `
        -Body $body `
        -Description "Create domain join profile $profileName"

    Write-Ok "Created domain join profile '$profileName' (OU: $OuDistinguishedName)"

    # Assign it to the same dynamic group
    $assignBody = @{
        assignments = @(
            @{
                target = @{
                    '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                    groupId       = $GroupId
                }
            }
        )
    }

    Invoke-GraphCall -Method POST `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($djProfile.id)/assign" `
        -Body $assignBody `
        -Description 'Assign domain join profile' | Out-Null

    Write-Ok 'Domain join profile assigned to group'
    return $djProfile
}

#endregion Autopilot Profile Functions

#region Main Wizard

Write-Banner 'Windows Autopilot Environment Builder'
if ($WhatIfMode) {
    Write-Host '  RUNNING IN WHATIF MODE - nothing will be created' -ForegroundColor Magenta
}

# Reset cached tenant state so re-runs in the same console session are fresh
$script:ProfileCache = $null

Connect-BuilderGraph

# --- Step 1: Join type -------------------------------------------------------
Write-Banner 'Step 1 of 5: Join Type'
Write-Host @'
   [1] Entra join   (recommended by Microsoft; simpler, no DC dependency)
   [2] Hybrid join  (requires Intune Connector for AD + DC line of sight
                     or VPN during provisioning)
'@
$joinChoice = Read-Answer 'Select join type (1 or 2)' '1'
$joinType   = if ($joinChoice -eq '2') { 'hybrid' } else { 'entra' }

$domainFqdn = $null
if ($joinType -eq 'hybrid') {
    Write-Host ''
    Write-Host '   Hybrid join prerequisites (verify before proceeding):' -ForegroundColor Yellow
    Write-Host '     - Intune Connector for Active Directory installed and healthy'
    Write-Host '     - Connector server computer account has delegated rights to'
    Write-Host '       create computer objects in the target OU(s)'
    Write-Host '     - Devices will have DC connectivity during provisioning'
    Write-Host ''
    $domainFqdn = Read-Answer 'On-prem AD domain FQDN (e.g. corp.contoso.com)'
}

# --- Step 2: Departments -----------------------------------------------------
Write-Banner 'Step 2 of 5: Departments'
Write-Host '   Enter your departments/personas as a comma-separated list.'
Write-Host '   Examples: Engineering, AdvanceSteel, Knockdown, PreAssembly, Sales, Office'
$deptRaw = Read-Answer 'Departments'
$departments = @($deptRaw -split ',' | ForEach-Object { ($_.Trim() -replace '\s+', '') } | Where-Object { $_ })

if ($departments.Count -eq 0) {
    Write-Host 'No departments entered. Exiting.' -ForegroundColor Red
    return
}

# Confirm/override group tags
$deptPlan = @()
Write-Host ''
Write-Host '   Each department gets a Group Tag. Devices imported into Autopilot' -ForegroundColor DarkGray
Write-Host '   with this tag automatically join the right group and profile.' -ForegroundColor DarkGray
foreach ($dept in $departments) {
    $suggested = ConvertTo-GroupTag $dept
    $tag = Read-Answer "   Group Tag for '$dept'" $suggested
    $tag = ($tag -replace '[^A-Za-z0-9]', '').ToUpper()

    $entry = [pscustomobject]@{
        Department    = $dept
        GroupTag      = $tag
        Ou            = $null
        RequiredApps  = @()
        AvailableApps = @()
        Group         = $null
        Profile       = $null
    }

    if ($joinType -eq 'hybrid') {
        $entry.Ou = Read-Answer "   Target OU DN for '$dept' (e.g. OU=$dept,OU=Workstations,DC=corp,DC=contoso,DC=com)"
    }
    $deptPlan += $entry
}

# --- Step 3: Application selection -------------------------------------------
Write-Banner 'Step 3 of 5: Application Assignments'
$apps = Get-IntuneAppInventory
if ($apps.Count -eq 0) {
    Write-Host '   No apps found in Intune. Skipping app assignment.' -ForegroundColor DarkYellow
}
else {
    Show-AppMenu -Apps $apps
    Write-Host '   For each department, choose apps by number. Formats: 1,3,5-8 or blank for none.' -ForegroundColor DarkGray
    foreach ($entry in $deptPlan) {
        Write-Host ''
        Write-Host "   --- $($entry.Department) ---" -ForegroundColor Cyan
        $reqRaw = Read-Host "   REQUIRED apps (auto-install) for $($entry.Department)"
        $avlRaw = Read-Host "   AVAILABLE apps (Company Portal) for $($entry.Department)"
        $reqIdx = ConvertTo-SelectionIndexes -InputText $reqRaw -Max $apps.Count
        $avlIdx = ConvertTo-SelectionIndexes -InputText $avlRaw -Max $apps.Count
        # Don't double-assign an app as both required and available
        $avlIdx = @($avlIdx | Where-Object { $_ -notin $reqIdx })
        $entry.RequiredApps  = @($reqIdx | ForEach-Object { $apps[$_ - 1] })
        $entry.AvailableApps = @($avlIdx | ForEach-Object { $apps[$_ - 1] })
    }
}

# --- Step 4: Review ----------------------------------------------------------
Write-Banner 'Step 4 of 5: Review Plan'
Write-Host "   Join type : $joinType"
if ($domainFqdn) { Write-Host "   AD domain : $domainFqdn" }
foreach ($entry in $deptPlan) {
    Write-Host ''
    Write-Host "   $($entry.Department)" -ForegroundColor Cyan
    Write-Host "     Group Tag      : $($entry.GroupTag)"
    Write-Host "     Dynamic group  : $($Config.GroupNameTemplate.Replace('{prefix}',$Config.NamingPrefix).Replace('{dept}',$entry.Department))"
    Write-Host "     Deploy profile : $($Config.ProfileNameTemplate.Replace('{prefix}',$Config.NamingPrefix).Replace('{dept}',$entry.Department))"
    if ($entry.Ou) { Write-Host "     Target OU      : $($entry.Ou)" }
    Write-Host "     Required apps  : $(@($entry.RequiredApps.DisplayName) -join ', ')"
    Write-Host "     Available apps : $(@($entry.AvailableApps.DisplayName) -join ', ')"
}
Write-Host ''
if (-not (Read-YesNo 'Proceed with this plan?')) {
    Write-Host 'Aborted. Nothing was created.' -ForegroundColor Red
    return
}

# --- Step 5: Build -----------------------------------------------------------
Write-Banner 'Step 5 of 5: Building'
foreach ($entry in $deptPlan) {
    Write-Step "Department: $($entry.Department)"

    # 5a. Dynamic group
    $entry.Group = New-AutopilotDeptGroup -Department $entry.Department -GroupTag $entry.GroupTag

    # 5b. Deployment profile
    $entry.Profile = New-AutopilotProfile -Department $entry.Department -GroupTag $entry.GroupTag -JoinType $joinType

    # 5c. Assign profile to group
    Set-AutopilotProfileAssignment -ProfileId $entry.Profile.id -GroupId $entry.Group.id

    # 5d. Hybrid: domain join profile
    if ($joinType -eq 'hybrid') {
        New-DomainJoinProfile -Department $entry.Department -GroupTag $entry.GroupTag `
            -DomainFqdn $domainFqdn -OuDistinguishedName $entry.Ou -GroupId $entry.Group.id | Out-Null
    }

    # 5e. App assignments
    foreach ($app in $entry.RequiredApps) {
        Set-AppAssignment -AppId $app.Id -AppName $app.DisplayName -GroupId $entry.Group.id -Intent 'required'
    }
    foreach ($app in $entry.AvailableApps) {
        Set-AppAssignment -AppId $app.Id -AppName $app.DisplayName -GroupId $entry.Group.id -Intent 'available'
    }
}

# --- Summary ------------------------------------------------------------------
Write-Banner 'Complete'
Write-Host @'
   Next steps:
     1. Import device hardware hashes into Autopilot with the matching
        Group Tag for each department (see runbook, Section 6).
     2. Allow up to 24h (usually minutes) for dynamic group membership
        and profile assignment status to show "Assigned".
     3. Configure an Enrollment Status Page if you have not already
        (see runbook, Section 8).
     4. Wipe or reset a test device and validate the OOBE flow end to end.
'@
Write-Host ''

#endregion Main Wizard
