function Set-ToolkitNotebookMarker {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MarkerPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ExportVersion,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BaselineCommit,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$BaselineTag,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Branch,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PreviousBaselineCommit,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$NextFeature
    )

    $markerDirectory = Split-Path `
        -Path $MarkerPath `
        -Parent

    if ([string]::IsNullOrWhiteSpace($markerDirectory)) {
        throw 'MarkerPath must include a parent directory.'
    }

    if (-not (Test-Path -LiteralPath $markerDirectory)) {
        New-Item `
            -Path $markerDirectory `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop |
            Out-Null
    }

    $generatedAt = Get-Date `
        -Format 'yyyy-MM-dd HH:mm:ss zzz'

    $normalizedBaselineTag = if (
        [string]::IsNullOrWhiteSpace($BaselineTag)
    ) {
        'None'
    }
    else {
        $BaselineTag.Trim()
    }

    $normalizedPreviousBaseline = if (
        [string]::IsNullOrWhiteSpace($PreviousBaselineCommit)
    ) {
        'None'
    }
    else {
        $PreviousBaselineCommit.Trim()
    }

    $normalizedNextFeature = if (
        [string]::IsNullOrWhiteSpace($NextFeature)
    ) {
        'Not specified'
    }
    else {
        $NextFeature.Trim()
    }

    $content = @"
# O365 Toolkit Private NotebookLM Marker

Export Version: $($ExportVersion.Trim())
Generated: $generatedAt
Baseline Commit: $($BaselineCommit.Trim())
Baseline Tag: $normalizedBaselineTag
Branch: $($Branch.Trim())
Previous Baseline Commit: $normalizedPreviousBaseline
Next Feature: $normalizedNextFeature

Classification: Private
Repository Visibility: Public
Storage Rule: Do not commit this file or generated private ZIP files to GitHub.

Next Export Rule:
Use commit $($BaselineCommit.Trim()) as the starting baseline.
"@

    Set-Content `
        -LiteralPath $MarkerPath `
        -Value $content.TrimEnd() `
        -Encoding utf8 `
        -ErrorAction Stop

    return [pscustomobject]@{
        Success                 = $true
        MarkerPath              = $MarkerPath
        ExportVersion           = $ExportVersion.Trim()
        BaselineCommit          = $BaselineCommit.Trim()
        BaselineTag             = $normalizedBaselineTag
        Branch                  = $Branch.Trim()
        PreviousBaselineCommit  = $normalizedPreviousBaseline
        NextFeature             = $normalizedNextFeature
        GeneratedAt             = $generatedAt
    }
}