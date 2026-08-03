function New-ToolkitNotebookDocuments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $true)]
        [string]$ExportVersion,

        [Parameter(Mandatory = $true)]
        [string]$NextFeature
    )

    process {
        Write-Host "Generating dynamic NotebookLM documentation set ($ExportVersion)..." -ForegroundColor Cyan

        if (-not (Test-Path $OutputDirectory)) {
            New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
        }

        # Dynamically discover all public functions across all modules
        $modulesDir = "$PSScriptRoot\..\..\..\Modules"
        $discoveredFunctions = @()
        if (Test-Path $modulesDir) {
            $publicScriptFiles = Get-ChildItem -Path $modulesDir -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -like "*\Public\*" }
            foreach ($file in $publicScriptFiles) {
                $discoveredFunctions += [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            }
        }

        $funcListMd = if ($discoveredFunctions.Count -gt 0) {
            ($discoveredFunctions | ForEach-Object { "- $_" }) -join "`n"
        } else {
            "- Get-ToolkitUser`n- Get-ToolkitGroup"
        }

        # 1. Master Guide
        $masterGuideContent = @"
# O365 Management Toolkit - Master Guide ($ExportVersion)
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

## Overview
The O365 Management Toolkit is a modular, test-driven PowerShell automation suite designed for hybrid Microsoft 365 and Entra ID environments.

## Current Public Capabilities
$funcListMd

## Next Planned Feature
- $NextFeature

## Architecture Highlights
- **Core Framework**: Manages secure connection states, Graph REST requests, pagination, retry-after throttling handling, and error normalization.
- **Service Modules**: Domain-specific modules (`O365Toolkit.Entra`) providing clean, pipelined cmdlets.
- **NotebookLM Integration**: Automated workspace compiler packaging repository snapshots and module books for AI alignment.
"@
        $masterGuidePath = Join-Path $OutputDirectory 'O365Toolkit_Master_Guide.md'
        Set-Content -LiteralPath $masterGuidePath -Value $masterGuideContent -Encoding utf8

        # 2. Architecture & Design Document
        $architectureContent = @"
# Architecture and Design Specifications

## Module Boundary Model
1. **O365Toolkit.Core**: Foundation layer providing robust Graph interaction (`Invoke-ToolkitGraphRequest`), error handling, and session management.
2. **O365Toolkit.Entra**: Service layer exposing Entra ID identity and group management cmdlets ($funcListMd).
3. **O365Toolkit.NotebookLM**: Documentation and knowledge base compiler.

## Design Rules
- All cmdlets enforce strict parameter validation and robust pipeline support.
- Unit testing via Pester v6 is mandatory for all public functions.
- Stateless design: functions rely on session-wide Graph authentication established by Core.
"@
        $archPath = Join-Path $OutputDirectory 'Architecture.md'
        Set-Content -LiteralPath $archPath -Value $architectureContent -Encoding utf8

        Write-Host "PASS: Dynamic documentation files generated successfully in $OutputDirectory" -ForegroundColor Green
    }
}
