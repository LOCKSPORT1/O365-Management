<#
.SYNOPSIS
    Central connection helper for Microsoft Graph + Exchange Online.
    Dot-source this at the top of every other script in the toolkit.

.DESCRIPTION
    Every other script in this toolkit expects Graph and (optionally) EXO
    sessions to already be live. Rather than duplicating auth logic in
    every file, dot-source this one:

        . .\00-Setup\Connect-M365Services.ps1
        Connect-M365 -Services Graph,ExchangeOnline

    Supports both interactive (delegated, MFA-friendly, good for an admin
    running this by hand) and app-only (client secret or cert, good for
    scheduled tasks / NinjaRMM-triggered runs) auth.

    Exposes three functions:
        Connect-M365            - does the actual connecting
        Assert-M365Connection   - checks for a live session first, only
                                   connects if needed (this is the one
                                   every other script in the toolkit calls)
        Disconnect-M365         - tears down all sessions cleanly

.PARAMETER Services
    (On Connect-M365 / Assert-M365Connection) One or more of
    "Graph", "ExchangeOnline", "ComplianceCenter" indicating which
    session(s) the calling script needs.

.PARAMETER AuthMode
    (On Connect-M365 / Assert-M365Connection) One of "Interactive",
    "AppSecret", "Certificate". Defaults to "Interactive".

.PARAMETER Force
    (On Assert-M365Connection only) Skips the "already connected?" check
    and always (re)connects. Use this if connection detection misfires
    on your ExchangeOnlineManagement module version.

.EXAMPLE
    . .\00-Setup\Connect-M365Services.ps1
    Connect-M365 -Services Graph,ExchangeOnline -AuthMode Interactive
    # ... do work ...
    Disconnect-M365

.EXAMPLE
    # Typical usage from inside another toolkit script, right after param():
    . "$PSScriptRoot\..\00-Setup\Connect-M365Services.ps1"
    Assert-M365Connection -Services Graph -AuthMode $AuthMode

.NOTES
    Requires modules:
        Install-Module Microsoft.Graph -Scope CurrentUser
        Install-Module ExchangeOnlineManagement -Scope CurrentUser
    Run on PowerShell 7.x. PS 5.1 will work for Graph but EXO session
    reliability is noticeably worse on 5.1 - use pwsh.exe.
#>

#region Configuration
# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
$Global:M365Config = @{
    # Tenant GUID or *.onmicrosoft.com domain - used for Graph (-TenantId) auth.
    TenantId        = "<your-tenant-id-or-domain.onmicrosoft.com>"

    # Verified tenant domain (must be the *.onmicrosoft.com name, NOT the
    # tenant GUID) - required by Connect-ExchangeOnline/-Organization and
    # Connect-IPPSSession/-Organization for app-only auth.
    OrganizationDomain = "yourtenant.onmicrosoft.com"

    # App registration (client) ID - only needed for app-only auth (AppSecret/Certificate modes).
    ClientId        = "<app-registration-client-id>"

    # Thumbprint of the certificate used for unattended auth - preferred over client secret.
    CertThumbprint  = "<cert-thumbprint>"

    # Client secret string - avoid storing in plaintext; pull from a vault/secret store instead.
    ClientSecret    = ""

    # Delegated Graph scopes requested at interactive sign-in.
    GraphScopes     = @(
        "User.ReadWrite.All",
        "Group.ReadWrite.All",
        "Directory.ReadWrite.All",
        "DeviceManagementManagedDevices.ReadWrite.All",
        "DeviceManagementServiceConfig.ReadWrite.All",
        "Organization.Read.All"
    )
}
#endregion

function Connect-M365 {
    [CmdletBinding()]
    param(
        [ValidateSet("Graph","ExchangeOnline","ComplianceCenter")]
        [string[]]$Services = @("Graph"),

        [ValidateSet("Interactive","AppSecret","Certificate")]
        [string]$AuthMode = "Interactive"
    )

    if ($Services -contains "Graph") {
        try {
            switch ($AuthMode) {
                "Interactive" {
                    Connect-MgGraph -TenantId $Global:M365Config.TenantId -Scopes $Global:M365Config.GraphScopes -NoWelcome
                }
                "Certificate" {
                    Connect-MgGraph -TenantId $Global:M365Config.TenantId `
                        -ClientId $Global:M365Config.ClientId `
                        -CertificateThumbprint $Global:M365Config.CertThumbprint `
                        -NoWelcome
                }
                "AppSecret" {
                    $secureSecret = ConvertTo-SecureString $Global:M365Config.ClientSecret -AsPlainText -Force
                    $cred = New-Object System.Management.Automation.PSCredential($Global:M365Config.ClientId, $secureSecret)
                    Connect-MgGraph -TenantId $Global:M365Config.TenantId -ClientSecretCredential $cred -NoWelcome
                }
            }
            $ctx = Get-MgContext
            Write-Host "Connected to Graph as $($ctx.Account) [Tenant: $($ctx.TenantId)]" -ForegroundColor Green
        }
        catch {
            throw "Failed to connect to Microsoft Graph (AuthMode: $AuthMode): $($_.Exception.Message)"
        }
    }

    if ($Services -contains "ExchangeOnline") {
        try {
            if ($AuthMode -eq "Interactive") {
                Connect-ExchangeOnline -ShowBanner:$false
            }
            else {
                Connect-ExchangeOnline -CertificateThumbprint $Global:M365Config.CertThumbprint `
                    -AppId $Global:M365Config.ClientId `
                    -Organization $Global:M365Config.OrganizationDomain `
                    -ShowBanner:$false
            }
            Write-Host "Connected to Exchange Online." -ForegroundColor Green
        }
        catch {
            throw "Failed to connect to Exchange Online (AuthMode: $AuthMode): $($_.Exception.Message)"
        }
    }

    if ($Services -contains "ComplianceCenter") {
        # Needed for compliance searches / purge actions (email purge, eDiscovery).
        # The account or app used here needs the "eDiscovery Manager" or
        # "Organization Management" role in the Security & Compliance Center.
        try {
            if ($AuthMode -eq "Interactive") {
                Connect-IPPSSession
            }
            else {
                Connect-IPPSSession -CertificateThumbprint $Global:M365Config.CertThumbprint `
                    -AppId $Global:M365Config.ClientId `
                    -Organization $Global:M365Config.OrganizationDomain
            }
            Write-Host "Connected to Security & Compliance Center." -ForegroundColor Green
        }
        catch {
            throw "Failed to connect to Security & Compliance Center (AuthMode: $AuthMode): $($_.Exception.Message)"
        }
    }
}

function Disconnect-M365 {
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch {}
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    # Disconnect-ExchangeOnline also tears down the IPPSSession (Compliance Center) session
    # since both ride the same underlying connection in ExchangeOnlineManagement.
    Write-Host "Disconnected all M365 sessions." -ForegroundColor Yellow
}

function Assert-M365Connection {
    <#
    .SYNOPSIS
        Called at the top of every other script in this toolkit. Checks
        whether the required session(s) are already live and only calls
        Connect-M365 if they aren't - so each script is self-sufficient
        (works standalone, double-clicked or scheduled) without silently
        failing on a missing connection, but also without redundantly
        reconnecting every single time if you're already signed in from
        a previous script in the same session.

    .NOTES
        Detection is best-effort: Graph checks via Get-MgContext (reliable).
        Exchange/Compliance checks via Get-ConnectionInformation, which
        distinguishes session type by ConnectionUri - reliable on current
        ExchangeOnlineManagement versions, but if you're on an older module
        version and detection misfires, pass -Force to skip detection and
        always (re)connect.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet("Graph","ExchangeOnline","ComplianceCenter")]
        [string[]]$Services = @("Graph"),

        [ValidateSet("Interactive","AppSecret","Certificate")]
        [string]$AuthMode = "Interactive",

        [switch]$Force
    )

    $needed = @()

    if ($Force) {
        $needed = $Services
    }
    else {
        if ($Services -contains "Graph") {
            $ctx = $null
            try { $ctx = Get-MgContext } catch {}
            if (-not $ctx) { $needed += "Graph" }
        }

        if ($Services -contains "ExchangeOnline" -or $Services -contains "ComplianceCenter") {
            $connections = $null
            try { $connections = Get-ConnectionInformation -ErrorAction SilentlyContinue } catch {}

            $exoLive = $connections | Where-Object { $_.ConnectionUri -match "outlook\.office365\.com" }
            $ippsLive = $connections | Where-Object { $_.ConnectionUri -match "compliance\.protection\.outlook\.com" }

            if ($Services -contains "ExchangeOnline" -and -not $exoLive) { $needed += "ExchangeOnline" }
            if ($Services -contains "ComplianceCenter" -and -not $ippsLive) { $needed += "ComplianceCenter" }
        }
    }

    if ($needed.Count -gt 0) {
        Write-Host "[Connection check] Not yet connected to: $($needed -join ', ') - connecting now (AuthMode: $AuthMode)..." -ForegroundColor Cyan
        Connect-M365 -Services $needed -AuthMode $AuthMode
    }
    else {
        Write-Host "[Connection check] Already connected: $($Services -join ', ')" -ForegroundColor DarkGray
    }
}
