<#
.SYNOPSIS
    Standardized error-handling wrapper for toolbox operations.
.DESCRIPTION
    Provides Invoke-ToolboxSafely, which executes a scriptblock, logs success or failure via
    Write-ToolboxLog, optionally rethrows the caught error, and clears $Error afterward so
    subsequent operations start with a clean error state.
.PARAMETER N/A
    This file defines the Invoke-ToolboxSafely function; see that function's own parameters below.
.EXAMPLE
    . (Join-Path $PSScriptRoot '..\core\ErrorHandling.ps1')
    Invoke-ToolboxSafely -Operation 'Get-Mailboxes' -TenantName 'Tenant-Example-NA' -ScriptBlock { Get-Mailbox -ResultSize Unlimited }
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-ToolboxSafely {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$TenantName = 'GLOBAL',
        [string]$Operation = 'UnnamedOperation',
        [switch]$Rethrow
    )

    try {
        & $ScriptBlock
        Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "$Operation completed successfully."
    }
    catch {
        Write-ToolboxLog -TenantName $TenantName -Level 'ERROR' -Message "$Operation failed: $($_.Exception.Message)"
        if ($Rethrow) { throw }
    }
    finally {
        $Error.Clear()
    }
}
