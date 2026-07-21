<#
.SYNOPSIS
    Retry-with-exponential-backoff helper for toolbox operations.
.DESCRIPTION
    Provides Invoke-WithRetry, which invokes a scriptblock and retries on failure using
    exponential backoff (BaseDelaySeconds * 2^(attempt-1), capped at MaxDelaySeconds). Throttling
    errors (HTTP 429 / "Too Many Requests" / messages containing "throttl") are logged as such;
    all other errors are retried using the flat BaseDelaySeconds delay. The last failed attempt
    rethrows the original exception.
.PARAMETER N/A
    This file defines the Invoke-WithRetry function; see that function's own parameters below.
.EXAMPLE
    . (Join-Path $PSScriptRoot '..\core\Retry.ps1')
    Invoke-WithRetry -Operation 'Get-MgUser' -TenantName 'Tenant-Example-NA' -ScriptBlock { Get-MgUser -All }
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Upper bound (seconds) on the exponential backoff delay, regardless of attempt count.
$script:RetryMaxDelaySeconds = 60

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 5,
        [int]$BaseDelaySeconds = 5,
        [string]$TenantName = 'GLOBAL',
        [string]$Operation = 'RetryOperation'
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            $message = $_.Exception.Message
            $isLast = $attempt -eq $MaxAttempts
            $delay = [math]::Min(($BaseDelaySeconds * [math]::Pow(2, ($attempt - 1))), $script:RetryMaxDelaySeconds)
            if ($message -match '429' -or $message -match 'Too Many Requests' -or $message -match 'throttl') {
                Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "$Operation throttled on attempt $attempt. Waiting $delay seconds before retry."
                if ($isLast) { throw }
                Start-Sleep -Seconds $delay
            }
            else {
                Write-ToolboxLog -TenantName $TenantName -Level 'WARN' -Message "$Operation failed on attempt ${attempt}: $message"
                if ($isLast) { throw }
                Start-Sleep -Seconds $BaseDelaySeconds
            }
        }
    }
}
