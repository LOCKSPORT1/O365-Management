function Connect-ToolkitGraph {
    <#
    .SYNOPSIS
        Connects the toolkit to Microsoft Graph.

    .DESCRIPTION
        Imports Microsoft.Graph.Authentication, validates any existing Graph
        context, and reconnects when the tenant, environment, or scopes do not
        satisfy the toolkit configuration.

    .PARAMETER Config
        Toolkit configuration returned by Read-ToolkitConfig.

    .PARAMETER UseDeviceCode
        Uses device-code authentication instead of the normal interactive flow.

    .PARAMETER ForceReconnect
        Disconnects any current Graph context and creates a new connection.

    .PARAMETER PassThru
        Returns a structured connection result.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Config,

        [Parameter()]
        [switch]$UseDeviceCode,

        [Parameter()]
        [switch]$ForceReconnect,

        [Parameter()]
        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $component = 'GraphAuthentication'
    $startedAt = Get-Date

    $graphModule =
        Get-Module `
            -ListAvailable `
            -Name Microsoft.Graph.Authentication |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $graphModule) {
        throw (
            'Microsoft.Graph.Authentication is not installed. ' +
            'Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
        )
    }

    Import-Module `
        -Name Microsoft.Graph.Authentication `
        -MinimumVersion $graphModule.Version `
        -ErrorAction Stop

    $validation =
        Test-ToolkitGraphConnection `
            -Config $Config `
            -PassThru

    if ($validation.IsValid -and -not $ForceReconnect) {
        Write-ToolkitLog `
            -Config $Config `
            -Level Information `
            -Component $component `
            -Message 'Reusing the existing Microsoft Graph connection.'

        $result = [pscustomobject]@{
            PSTypeName            = 'O365Toolkit.GraphConnectionResult'
            Success               = $true
            ReusedExistingContext = $true
            ConnectedAt           = Get-Date
            Duration              = (Get-Date) - $startedAt
            Account               = $validation.Context.Account
            TenantId              = $validation.Context.TenantId
            Environment           = $validation.Context.Environment
            AuthType              = $validation.Context.AuthType
            Scopes                = @($validation.Context.Scopes)
            Context               = $validation.Context
        }

        if ($PassThru) {
            return $result
        }

        return
    }

    $existingContext = $null

    try {
    $existingContext = Get-MgContext -ErrorAction Stop
    }
    catch {
    if (
        $_.FullyQualifiedErrorId -match 'SessionNotInitialized' -or
        $_.Exception.Message -match 'SessionNotInitialized'
    ) {
        $existingContext = $null
    }
    else {
        throw
    }
    }

    if ($existingContext) {
        Write-ToolkitLog `
            -Config $Config `
            -Level Information `
            -Component $component `
            -Message 'Disconnecting the existing Microsoft Graph context.'

        Disconnect-MgGraph -ErrorAction Stop | Out-Null
    }

    $environment =
        Resolve-ToolkitGraphEnvironment `
            -CloudEnvironment ([string]$Config.Graph.CloudEnvironment)

    $scopes = @($Config.Graph.Scopes) |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        }

    if ($scopes.Count -eq 0) {
        throw 'Config.Graph.Scopes must contain at least one Microsoft Graph permission scope.'
    }

    $connectParameters = @{
        Scopes       = $scopes
        ContextScope = 'Process'
        Environment  = $environment
        NoWelcome    = $true
        ErrorAction  = 'Stop'
    }

    $tenantId = [string]$Config.Tenant.TenantId

    if (-not [string]::IsNullOrWhiteSpace($tenantId)) {
        $connectParameters.TenantId = $tenantId
    }

    if ($UseDeviceCode) {
        $connectParameters.UseDeviceCode = $true
    }

    Write-ToolkitLog `
        -Config $Config `
        -Level Information `
        -Component $component `
        -Message (
            'Connecting to Microsoft Graph. Environment: {0}; Scope count: {1}.' -f
            $environment,
            $scopes.Count
        )

    Connect-MgGraph @connectParameters

    $validation =
        Test-ToolkitGraphConnection `
            -Config $Config `
            -PassThru

    if (-not $validation.IsValid) {
        $missingScopeText =
            if ($validation.MissingScopes.Count -gt 0) {
                $validation.MissingScopes -join ', '
            }
            else {
                'None'
            }

        throw (
            'Microsoft Graph connection validation failed. ' +
            "Tenant match: $($validation.TenantMatches); " +
            "Environment match: $($validation.EnvironmentMatches); " +
            "Missing scopes: $missingScopeText"
        )
    }

    Write-ToolkitLog `
        -Config $Config `
        -Level Information `
        -Component $component `
        -Message (
            'Microsoft Graph connection established for {0}.' -f
            $validation.Context.Account
        )

    $result = [pscustomobject]@{
        PSTypeName            = 'O365Toolkit.GraphConnectionResult'
        Success               = $true
        ReusedExistingContext = $false
        ConnectedAt           = Get-Date
        Duration              = (Get-Date) - $startedAt
        Account               = $validation.Context.Account
        TenantId              = $validation.Context.TenantId
        Environment           = $validation.Context.Environment
        AuthType              = $validation.Context.AuthType
        Scopes                = @($validation.Context.Scopes)
        Context               = $validation.Context
    }

    if ($PassThru) {
        return $result
    }
}
