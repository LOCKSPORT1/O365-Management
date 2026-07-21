function Invoke-M365Connect {
<#!
.SYNOPSIS
Connects to one or more Microsoft 365 admin workloads for a configured tenant.
.DESCRIPTION
Wrapper around the toolbox connector script. This advanced function gives module users a cleaner entry point for Graph, Exchange, Purview, Teams, SharePoint, Azure, and Intune connectivity.
.PARAMETER TenantName
Tenant name from config/tenants.json.
.EXAMPLE
Invoke-M365Connect -TenantName Tenant-Example-Cloud -ConnectGraph -ConnectExchange
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantName,
        [switch]$ConnectGraph,
        [switch]$ConnectExchange,
        [switch]$ConnectPurview,
        [switch]$ConnectTeams,
        [switch]$ConnectSharePoint,
        [switch]$ConnectAzure,
        [switch]$ConnectIntune,
        [switch]$UseAppOnly,
        [string[]]$GraphScopes
    )
    & (Join-Path (Get-ToolboxRoot) 'core\Connect-M365.ps1') @PSBoundParameters
}

function Invoke-M365MailboxAudit {
<#!
.SYNOPSIS
Exports mailbox audit settings for a tenant.
.DESCRIPTION
Runs the mailbox audit script and exports mailbox settings to CSV.
.PARAMETER TenantName
Tenant name from config.
.EXAMPLE
Invoke-M365MailboxAudit -TenantName Tenant-Example-NA -SharedOnly
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantName,
        [string]$MailboxFilter = '*',
        [switch]$SharedOnly,
        [string]$OutputCsv = '.\reports\MailboxAudit.csv'
    )
    & (Join-Path (Get-ToolboxRoot) 'exchange\Audit-Mailboxes.ps1') @PSBoundParameters
}

function Invoke-M365UserOnboarding {
<#!
.SYNOPSIS
Creates a Microsoft 365 user and applies onboarding settings.
.DESCRIPTION
Advanced-function wrapper for the user lifecycle onboarding script.
.PARAMETER TenantName
Tenant name from config.
.EXAMPLE
Invoke-M365UserOnboarding -TenantName Tenant-Example-Cloud -DisplayName 'Jane Doe' -UserPrincipalName jane@example.com -MailNickname jane
#>
    [CmdletBinding(SupportsShouldProcess)]
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
    if ($PSCmdlet.ShouldProcess($UserPrincipalName,'Create and onboard user')) {
        & (Join-Path (Get-ToolboxRoot) 'lifecycle\New-UserLifecycle.ps1') @PSBoundParameters
    }
}

function Invoke-M365UserOffboarding {
<#!
.SYNOPSIS
Offboards a Microsoft 365 user.
.DESCRIPTION
Advanced-function wrapper for the user offboarding script with ShouldProcess support.
.PARAMETER TenantName
Tenant name from config.
.EXAMPLE
Invoke-M365UserOffboarding -TenantName Tenant-Example-NA -UserPrincipalName user@example.com -RemoveLicenses -RevokeSessions
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TenantName,
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [switch]$ConvertMailboxToShared,
        [switch]$RemoveLicenses,
        [switch]$DisableDevices,
        [switch]$RevokeSessions,
        [switch]$MoveOnPremObjectToDisabledOU
    )
    if ($PSCmdlet.ShouldProcess($UserPrincipalName,'Offboard user')) {
        & (Join-Path (Get-ToolboxRoot) 'lifecycle\Disable-UserLifecycle.ps1') @PSBoundParameters
    }
}

function Invoke-M365BulkOnboarding {
<#!
.SYNOPSIS
Runs bulk onboarding from CSV.
.DESCRIPTION
Wrapper for the bulk onboarding workflow.
.PARAMETER CsvPath
Path to the onboarding CSV.
.EXAMPLE
Invoke-M365BulkOnboarding -CsvPath .\templates\BulkUserOnboarding.csv
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CsvPath,
        [switch]$HybridCreateOnPremFirst
    )
    & (Join-Path (Get-ToolboxRoot) 'bulk\Invoke-BulkUserOnboarding.ps1') @PSBoundParameters
}

function Invoke-M365LicenseInventoryReport {
<#!
.SYNOPSIS
Exports Microsoft 365 license inventory.
.DESCRIPTION
Wrapper for the Graph-based license inventory report.
.PARAMETER TenantName
Tenant name from config.
.EXAMPLE
Invoke-M365LicenseInventoryReport -TenantName Tenant-Example-Cloud -IncludeServicePlans
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantName,
        [string]$OutputCsv = '.\reports\LicenseInventory.csv',
        [switch]$IncludeServicePlans,
        [switch]$IncludeUserAssignments
    )
    & (Join-Path (Get-ToolboxRoot) 'entra\Report-LicenseInventory.ps1') @PSBoundParameters
}

function Invoke-M365SecurityAuditExport {
<#!
.SYNOPSIS
Exports unified audit log data.
.DESCRIPTION
Wrapper for the compliance audit export workflow.
.PARAMETER TenantName
Tenant name from config.
.EXAMPLE
Invoke-M365SecurityAuditExport -TenantName Tenant-Example-NA -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date)
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantName,
        [Parameter(Mandatory)][datetime]$StartDate,
        [Parameter(Mandatory)][datetime]$EndDate,
        [string]$OutputCsv = '.\reports\ComplianceAuditData.csv',
        [string]$RecordType = 'ExchangeAdmin'
    )
    & (Join-Path (Get-ToolboxRoot) 'security\Export-ComplianceAuditData.ps1') @PSBoundParameters
}
