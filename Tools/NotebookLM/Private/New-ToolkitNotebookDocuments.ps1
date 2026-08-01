function New-ToolkitNotebookDocuments {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Snapshot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ExportVersion,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$NextFeature,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$TestSummary
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item `
            -Path $OutputPath `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop |
            Out-Null
    }

    $generatedAt = Get-Date `
        -Format 'yyyy-MM-dd HH:mm:ss zzz'

    $normalizedNextFeature = if (
        [string]::IsNullOrWhiteSpace($NextFeature)
    ) {
        'Not specified'
    }
    else {
        $NextFeature.Trim()
    }

    $normalizedTestSummary = if (
        [string]::IsNullOrWhiteSpace($TestSummary)
    ) {
        'Tests were not run during this export.'
    }
    else {
        $TestSummary.Trim()
    }

    $commitLogText = if (
        $Snapshot.CommitLog.Count -gt 0
    ) {
        $Snapshot.CommitLog -join [environment]::NewLine
    }
    else {
        'No commits were detected in the incremental range.'
    }

    $diffStatText = if (
        $Snapshot.DiffStat.Count -gt 0
    ) {
        $Snapshot.DiffStat -join [environment]::NewLine
    }
    else {
        'No diff statistics were available.'
    }

    $changedFilesText = if (
        $Snapshot.ChangedFiles.Count -gt 0
    ) {
        $Snapshot.ChangedFiles -join [environment]::NewLine
    }
    else {
        'No changed files were detected.'
    }

    $masterGuide = @"
# O365 Management Toolkit - Private NotebookLM Guide

Generated: $generatedAt
Export Version: $ExportVersion

## Repository Baseline

- Branch: $($Snapshot.Branch)
- Current Commit: $($Snapshot.CurrentCommit)
- Latest Tag: $($Snapshot.LatestTag)
- Previous Baseline: $($Snapshot.PreviousBaselineCommit)
- Incremental Range: $($Snapshot.IncrementalRange)
- Working Tree Clean: $($Snapshot.IsClean)

## Current Architecture

The toolkit uses a shared Core module for:

- configuration
- logging
- Microsoft Graph authentication
- connection validation
- retry handling
- Graph error normalization
- automatic paging
- request telemetry

Service-specific modules consume the Core layer.

## Current Service Modules

### O365Toolkit.Entra

Current public capability:

- Get-ToolkitUser

Supported filters:

- user principal name
- department
- licensed users only
- PassThru metadata

## Test Summary

$normalizedTestSummary

## Next Planned Feature

$normalizedNextFeature
"@

    $timeline = @"
# Development Timeline

Generated: $generatedAt

## Included Commit Range

$($Snapshot.IncrementalRange)

## Commits

$commitLogText

## Diff Summary

$diffStatText

## Changed Files

$changedFilesText
"@

    $architecture = @"
# Architecture

## Core Layer

The Core module provides reusable infrastructure for all future
Microsoft 365 service modules.

## Public Graph API

Invoke-ToolkitGraphRequest is the single public Graph request entry
point.

## Private Graph Helpers

Private helpers handle:

- retries
- retry delays
- Graph errors
- paging
- next-link traversal

## Entra Layer

O365Toolkit.Entra currently exposes Get-ToolkitUser and relies on the
Core request framework.

## NotebookLM Export Layer

The NotebookLM framework creates private documentation packages outside
the public repository.

Its incremental baseline is stored in SESSION_MARKER_PRIVATE.md.
"@

    $decisions = @"
# Design Decisions

## Private exports

NotebookLM ZIP files and private markers are stored outside the public
GitHub repository.

## Incremental exports

Each export stores its current commit as the next baseline.

Future exports compare that baseline to the current repository HEAD.

## Clean repository requirement

Final exports should only be created from a committed, clean repository
state.

## Public versus private functions

Only New-ToolkitNotebookExport will be exported publicly.

Git, marker, snapshot, document-generation, and compression helpers
remain private.
"@

    $prompts = @"
Suggested NotebookLM Prompts

1. Explain the toolkit architecture.
2. Summarize changes since the previous export.
3. Explain the Graph retry and paging framework.
4. Explain Get-ToolkitUser.
5. Create a developer onboarding guide.
6. Identify production-hardening opportunities.
7. Create interview talking points from this project.
8. Explain the release and branching workflow.
9. List the next logical Entra capabilities.
10. Compare the current baseline with the previous baseline.
"@

    $documents = [ordered]@{
        'O365Toolkit_Master_Guide.md' = $masterGuide
        'Development_Timeline.md'     = $timeline
        'Architecture.md'             = $architecture
        'Decisions.md'                = $decisions
        'NotebookLM_Prompts.txt'      = $prompts
    }

    $createdFiles = foreach ($entry in $documents.GetEnumerator()) {
        $destination = Join-Path `
            -Path $OutputPath `
            -ChildPath $entry.Key

        Set-Content `
            -LiteralPath $destination `
            -Value $entry.Value.TrimEnd() `
            -Encoding utf8 `
            -ErrorAction Stop

        Get-Item `
            -LiteralPath $destination `
            -ErrorAction Stop
    }

    return [pscustomobject]@{
        Success      = $true
        OutputPath   = $OutputPath
        ExportVersion = $ExportVersion
        CreatedFiles = @($createdFiles)
        FileCount    = @($createdFiles).Count
        GeneratedAt  = $generatedAt
    }
}