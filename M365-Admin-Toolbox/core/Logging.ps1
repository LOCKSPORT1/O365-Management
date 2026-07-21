<#
.SYNOPSIS
    Session transcript helpers for the toolbox.
.DESCRIPTION
    Provides Start-ToolboxTranscript to begin a PowerShell transcript under
    logs\transcripts\<Prefix>_<TenantName>_<timestamp>.txt, and Stop-ToolboxTranscript to safely
    stop it (swallowing errors if no transcript is active).
.PARAMETER N/A
    This file defines Start-ToolboxTranscript and Stop-ToolboxTranscript; see those functions'
    own parameters below.
.EXAMPLE
    . (Join-Path $PSScriptRoot '..\core\Logging.ps1')
    $path = Start-ToolboxTranscript -TenantName 'Tenant-Example-NA' -Prefix 'Onboarding'
    Stop-ToolboxTranscript
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

function Start-ToolboxTranscript {
    param(
        [string]$TenantName = 'GLOBAL',
        [string]$Prefix = 'Session'
    )
    $root = Get-ToolboxRoot
    $logDir = Join-Path $root 'logs\transcripts'
    Ensure-Directory -Path $logDir
    $path = Join-Path $logDir ("{0}_{1}_{2}.txt" -f $Prefix, $TenantName, (Get-Date -Format 'yyyyMMddHHmmss'))
    Start-Transcript -Path $path -Force | Out-Null
    return $path
}

function Stop-ToolboxTranscript {
    try { Stop-Transcript | Out-Null } catch {}
}
