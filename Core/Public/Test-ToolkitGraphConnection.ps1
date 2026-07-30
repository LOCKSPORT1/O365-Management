function Test-ToolkitGraphConnection {
    <#
    .SYNOPSIS
        Validates the current Microsoft Graph PowerShell connection.

    .DESCRIPTION
        Confirms that a Graph context exists and validates the configured
        tenant, cloud environment, and required delegated scopes.

    .PARAMETER Config
        Toolkit configuration returned by Read-ToolkitConfig.

    .PARAMETER PassThru
        Returns a detailed validation object instead of a Boolean value.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Config,

        [Parameter()]
        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $requiredScopes = @($Config.Graph.Scopes) |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        } |
        ForEach-Object {
            [string]$_
        }

    $configuredTenantId = [string]$Config.Tenant.TenantId

    $expectedEnvironment =
        Resolve-ToolkitGraphEnvironment `
            -CloudEnvironment ([string]$Config.Graph.CloudEnvironment)

    $context = $null

    if (Get-Command Get-MgContext -ErrorAction SilentlyContinue) {
    try {
        $context = Get-MgContext -ErrorAction Stop
    }
    catch {
        if (
            $_.FullyQualifiedErrorId -match 'SessionNotInitialized' -or
            $_.Exception.Message -match 'SessionNotInitialized'
        ) {
            $context = $null
        }
        else {
            throw
        }
    }
}
    

    $connected = $null -ne $context

    $tenantMatches =
        $connected -and (
            [string]::IsNullOrWhiteSpace($configuredTenantId) -or
            $context.TenantId -eq $configuredTenantId
        )

    $environmentMatches =
        $connected -and
        $context.Environment -eq $expectedEnvironment

    $currentScopes =
        if ($connected) {
            @($context.Scopes)
        }
        else {
            @()
        }

    $missingScopes = @(
        foreach ($requiredScope in $requiredScopes) {
            if (
                -not (
                    $currentScopes |
                    Where-Object {
                        $_ -ieq $requiredScope
                    }
                )
            ) {
                $requiredScope
            }
        }
    )

    $scopesMatch =
        $connected -and
        $missingScopes.Count -eq 0

    $isValid =
        $connected -and
        $tenantMatches -and
        $environmentMatches -and
        $scopesMatch

    $result = [pscustomobject]@{
        PSTypeName         = 'O365Toolkit.GraphConnectionTest'
        IsValid            = $isValid
        Connected          = $connected
        TenantMatches      = $tenantMatches
        EnvironmentMatches = $environmentMatches
        ScopesMatch        = $scopesMatch
        ExpectedTenantId   = $configuredTenantId
        CurrentTenantId    = if ($connected) { $context.TenantId } else { $null }
        ExpectedEnvironment = $expectedEnvironment
        CurrentEnvironment = if ($connected) { $context.Environment } else { $null }
        RequiredScopes     = $requiredScopes
        CurrentScopes      = $currentScopes
        MissingScopes      = $missingScopes
        Context            = $context
    }

    if ($PassThru) {
        return $result
    }

    return $result.IsValid
}
