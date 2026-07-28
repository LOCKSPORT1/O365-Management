function Connect-PrimaryUserAuditGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph using the permissions required by the audit.

    .DESCRIPTION
        Uses delegated authentication for the Primary User Audit tool.

        Audit mode requests read-only permissions.

        Fix mode adds DeviceManagementManagedDevices.ReadWrite.All so the tool
        can update Intune primary-user assignments.

        If an existing Microsoft Graph connection already contains all required
        permissions, that connection is reused.

    .PARAMETER Fix
        Requests the write permission required for remediation.

    .PARAMETER TenantId
        Optional Microsoft Entra tenant ID.

    .PARAMETER UseDeviceCode
        Uses device-code authentication instead of the normal browser sign-in.

    .EXAMPLE
        Connect-PrimaryUserAuditGraph

    .EXAMPLE
        Connect-PrimaryUserAuditGraph -Fix

    .EXAMPLE
        Connect-PrimaryUserAuditGraph `
            -TenantId "00000000-0000-0000-0000-000000000000" `
            -UseDeviceCode
    #>

    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Fix,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,

        [Parameter()]
        [switch]$UseDeviceCode
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $authenticationModule = Get-Module `
        -ListAvailable `
        -Name Microsoft.Graph.Authentication |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $authenticationModule) {
        throw @"
The Microsoft.Graph.Authentication module is not installed.

Install it with:

Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
"@
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $requiredScopes = [System.Collections.Generic.List[string]]::new()

    $requiredScopes.Add('AuditLog.Read.All')
    $requiredScopes.Add('User.Read.All')
    $requiredScopes.Add('DeviceManagementManagedDevices.Read.All')

    if ($Fix) {
        $requiredScopes.Add('DeviceManagementManagedDevices.ReadWrite.All')
    }

    $requiredScopes = @(
        $requiredScopes |
        Sort-Object -Unique
    )

    $existingContext = Get-MgContext -ErrorAction SilentlyContinue
    $reuseExistingConnection = $false

    if ($existingContext) {
        $missingScopes = @(
            $requiredScopes |
            Where-Object {
                $_ -notin @($existingContext.Scopes)
            }
        )

        $tenantMatches = $true

        if (
            -not [string]::IsNullOrWhiteSpace($TenantId) -and
            $existingContext.TenantId -ne $TenantId
        ) {
            $tenantMatches = $false
        }

        if ($missingScopes.Count -eq 0 -and $tenantMatches) {
            $reuseExistingConnection = $true
        }
    }

    if ($reuseExistingConnection) {
        Write-Verbose (
            "Reusing Microsoft Graph connection for account {0} in tenant {1}." -f
            $existingContext.Account,
            $existingContext.TenantId
        )

        return $existingContext
    }

    $connectionParameters = @{
        Scopes       = $requiredScopes
        ContextScope = 'Process'
        NoWelcome    = $true
        ErrorAction  = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $connectionParameters.TenantId = $TenantId
    }

    if ($UseDeviceCode) {
        $connectionParameters.UseDeviceCode = $true
    }

    try {
        Connect-MgGraph @connectionParameters
    }
    catch {
        throw "Microsoft Graph authentication failed: $($_.Exception.Message)"
    }

    $newContext = Get-MgContext -ErrorAction Stop

    if (-not $newContext) {
        throw 'Microsoft Graph authentication completed, but no Graph context was returned.'
    }

    $missingScopesAfterConnection = @(
        $requiredScopes |
        Where-Object {
            $_ -notin @($newContext.Scopes)
        }
    )

    if ($missingScopesAfterConnection.Count -gt 0) {
        throw (
            "The Graph connection is missing required permissions: {0}" -f
            ($missingScopesAfterConnection -join ', ')
        )
    }

    Write-Verbose (
        "Connected to Microsoft Graph as {0} in tenant {1}." -f
        $newContext.Account,
        $newContext.TenantId
    )

    return $newContext
}