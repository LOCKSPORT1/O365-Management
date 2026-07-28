function Export-PrimaryUserAuditReport {
    <#
    .SYNOPSIS
        Exports Primary User Audit results to CSV files.

    .DESCRIPTION
        Creates:

        - A complete audit report containing every analyzed device
        - An action report containing only Assign, Change, and Review results
        - A summary object for display or later automation

    .PARAMETER Recommendations
        Results returned by Get-PrimaryUserRecommendation.

    .PARAMETER OutputFolder
        Folder where reports will be created.

    .PARAMETER Prefix
        Prefix used in generated report filenames.

    .PARAMETER PassThru
        Returns the generated report summary object.

    .EXAMPLE
        Export-PrimaryUserAuditReport `
            -Recommendations $Recommendations `
            -PassThru
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object[]]$Recommendations,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OutputFolder = (
            Join-Path $PSScriptRoot '..\Reports'
        ),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Prefix = 'PrimaryUserAudit',

        [Parameter()]
        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $resolvedOutputFolder = [System.IO.Path]::GetFullPath(
        $OutputFolder
    )

    if (-not (Test-Path $resolvedOutputFolder)) {
        $null = New-Item `
            -Path $resolvedOutputFolder `
            -ItemType Directory `
            -Force
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    $fullReportPath = Join-Path `
        $resolvedOutputFolder `
        "${Prefix}_Full_$timestamp.csv"

    $actionReportPath = Join-Path `
        $resolvedOutputFolder `
        "${Prefix}_Actions_$timestamp.csv"

    $summaryReportPath = Join-Path `
        $resolvedOutputFolder `
        "${Prefix}_Summary_$timestamp.csv"

    $sortedRecommendations = @(
        $Recommendations |
        Sort-Object `
            @{
                Expression = {
                    switch ($_.RecommendedAction) {
                        'Change'     { 1 }
                        'Assign'     { 2 }
                        'Review'     { 3 }
                        'NoChange'   { 4 }
                        'NoEvidence' { 5 }
                        default      { 6 }
                    }
                }
            },
            DeviceName
    )

    $sortedRecommendations |
        Export-Csv `
            -Path $fullReportPath `
            -NoTypeInformation `
            -Encoding UTF8

    $actionResults = @(
        $sortedRecommendations |
        Where-Object {
            $_.RecommendedAction -in @(
                'Assign',
                'Change',
                'Review'
            )
        }
    )

    $actionResults |
        Select-Object `
            DeviceName,
            ManagedDeviceId,
            EntraDeviceId,
            SerialNumber,
            Manufacturer,
            Model,
            CurrentUserPrincipal,
            RecommendedUserPrincipal,
            TotalSignIns,
            LeadingUserSignIns,
            SecondPlaceSignIns,
            DominancePercent,
            Confidence,
            RecommendedAction,
            Reason,
            LastSyncDateTime |
        Export-Csv `
            -Path $actionReportPath `
            -NoTypeInformation `
            -Encoding UTF8

    $summary = [pscustomobject]@{
        GeneratedDateTime = Get-Date
        TotalDevices      = $Recommendations.Count
        AssignCount       = @(
            $Recommendations |
            Where-Object RecommendedAction -eq 'Assign'
        ).Count
        ChangeCount       = @(
            $Recommendations |
            Where-Object RecommendedAction -eq 'Change'
        ).Count
        ReviewCount       = @(
            $Recommendations |
            Where-Object RecommendedAction -eq 'Review'
        ).Count
        NoChangeCount     = @(
            $Recommendations |
            Where-Object RecommendedAction -eq 'NoChange'
        ).Count
        NoEvidenceCount   = @(
            $Recommendations |
            Where-Object RecommendedAction -eq 'NoEvidence'
        ).Count
        HighConfidenceCount = @(
            $Recommendations |
            Where-Object Confidence -eq 'High'
        ).Count
        FullReportPath    = $fullReportPath
        ActionReportPath  = $actionReportPath
        SummaryReportPath = $summaryReportPath
    }

    $summary |
        Export-Csv `
            -Path $summaryReportPath `
            -NoTypeInformation `
            -Encoding UTF8

    Write-Host ''
    Write-Host 'Primary User Audit report completed.'
    Write-Host "Total devices:     $($summary.TotalDevices)"
    Write-Host "Assignments:       $($summary.AssignCount)"
    Write-Host "Changes:           $($summary.ChangeCount)"
    Write-Host "Manual reviews:    $($summary.ReviewCount)"
    Write-Host "No changes:        $($summary.NoChangeCount)"
    Write-Host "No evidence:       $($summary.NoEvidenceCount)"
    Write-Host ''
    Write-Host "Full report:       $fullReportPath"
    Write-Host "Action report:     $actionReportPath"
    Write-Host "Summary report:    $summaryReportPath"

    if ($PassThru) {
        return $summary
    }
}