function Invoke-PrimaryUserAudit {
    <#
    .SYNOPSIS
        Runs the complete Microsoft Intune primary-user audit.

    .DESCRIPTION
        Performs a read-only primary-user audit by:

        1. Connecting to Microsoft Graph
        2. Retrieving managed Windows devices
        3. Retrieving Entra sign-in evidence
        4. Calculating primary-user recommendations
        5. Exporting full, action, and summary reports

        This command does not modify Intune primary-user assignments.

    .PARAMETER Days
        Number of days of Entra sign-in activity to analyze.

    .PARAMETER MinimumSignIns
        Minimum number of qualifying sign-ins required before recommending
        an assignment or change.

    .PARAMETER MinimumDominancePercent
        Minimum percentage of sign-ins that must belong to the leading user.

    .PARAMETER OutputFolder
        Folder where report files will be created.

    .PARAMETER TenantId
        Optional Microsoft Entra tenant ID.

    .PARAMETER UseDeviceCode
        Uses device-code authentication instead of browser authentication.

    .PARAMETER IncludeNonCompliant
        Includes noncompliant Intune devices.

    .PARAMETER IncludeRetired
        Includes retired Intune devices.

    .PARAMETER IncludeNonInteractive
        Includes non-interactive sign-ins in confidence calculations.

    .PARAMETER PassThru
        Returns devices, evidence, recommendations, and report information.

    .EXAMPLE
        Invoke-PrimaryUserAudit

    .EXAMPLE
        Invoke-PrimaryUserAudit `
            -Days 30 `
            -MinimumSignIns 5 `
            -MinimumDominancePercent 70

    .EXAMPLE
        $Audit = Invoke-PrimaryUserAudit -PassThru
    #>

    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 365)]
        [int]$Days = 30,

        [Parameter()]
        [ValidateRange(1, 10000)]
        [int]$MinimumSignIns = 5,

        [Parameter()]
        [ValidateRange(1, 100)]
        [double]$MinimumDominancePercent = 70,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OutputFolder = (
            Join-Path $PSScriptRoot '..\Reports'
        ),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,

        [Parameter()]
        [switch]$UseDeviceCode,

        [Parameter()]
        [switch]$IncludeNonCompliant,

        [Parameter()]
        [switch]$IncludeRetired,

        [Parameter()]
        [switch]$IncludeNonInteractive,

        [Parameter()]
        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $requiredFunctions = @(
        'Connect-PrimaryUserAuditGraph'
        'Get-ManagedWindowsDevice'
        'Get-DeviceSignInEvidence'
        'Get-PrimaryUserRecommendation'
        'Export-PrimaryUserAuditReport'
    )

    $missingFunctions = @(
        foreach ($functionName in $requiredFunctions) {
            if (
                -not (
                    Get-Command `
                        -Name $functionName `
                        -ErrorAction SilentlyContinue
                )
            ) {
                $functionName
            }
        }
    )

    if ($missingFunctions.Count -gt 0) {
        throw (
            'The following required functions are not loaded: {0}' -f
            ($missingFunctions -join ', ')
        )
    }

    $auditStartTime = Get-Date

    Write-Host ''
    Write-Host '=============================================='
    Write-Host ' Microsoft 365 Primary User Audit'
    Write-Host '=============================================='
    Write-Host "Start time:            $auditStartTime"
    Write-Host "Sign-in lookback:      $Days days"
    Write-Host "Minimum sign-ins:      $MinimumSignIns"
    Write-Host "Minimum dominance:     $MinimumDominancePercent%"
    Write-Host ''

    try {
        Write-Host '[1/5] Connecting to Microsoft Graph...'

        $connectionParameters = @{}

        if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
            $connectionParameters.TenantId = $TenantId
        }

        if ($UseDeviceCode) {
            $connectionParameters.UseDeviceCode = $true
        }

        $graphContext = Connect-PrimaryUserAuditGraph `
            @connectionParameters

        Write-Host (
            '      Connected as {0}' -f
            $graphContext.Account
        )

        Write-Host '[2/5] Retrieving managed Windows devices...'

        $deviceParameters = @{}

        if ($IncludeNonCompliant) {
            $deviceParameters.IncludeNonCompliant = $true
        }

        if ($IncludeRetired) {
            $deviceParameters.IncludeRetired = $true
        }

        $devices = @(
            Get-ManagedWindowsDevice @deviceParameters
        )

        Write-Host (
            '      Retrieved {0} Windows devices.' -f
            $devices.Count
        )

        if ($devices.Count -eq 0) {
            throw 'No managed Windows devices were returned.'
        }

        Write-Host '[3/5] Retrieving Entra sign-in evidence...'

        $signInEvidence = @(
            Get-DeviceSignInEvidence `
                -Days $Days `
                -DeviceIds $devices.EntraDeviceId
        )

        Write-Host (
            '      Retrieved {0} qualifying sign-in records.' -f
            $signInEvidence.Count
        )

        Write-Host '[4/5] Calculating primary-user recommendations...'

        $recommendationParameters = @{
            Devices                  = $devices
            SignInEvidence           = $signInEvidence
            MinimumSignIns           = $MinimumSignIns
            MinimumDominancePercent  = $MinimumDominancePercent
        }

        if ($IncludeNonInteractive) {
            $recommendationParameters.IncludeNonInteractive = $true
        }

        $recommendations = @(
            Get-PrimaryUserRecommendation `
                @recommendationParameters
        )

        Write-Host (
            '      Evaluated {0} devices.' -f
            $recommendations.Count
        )

        Write-Host '[5/5] Exporting audit reports...'

        $reportSummary = Export-PrimaryUserAuditReport `
            -Recommendations $recommendations `
            -OutputFolder $OutputFolder `
            -PassThru

        $auditEndTime = Get-Date
        $duration = $auditEndTime - $auditStartTime

        Write-Host ''
        Write-Host '=============================================='
        Write-Host ' Audit completed successfully'
        Write-Host '=============================================='
        Write-Host (
            'Duration:              {0:hh\:mm\:ss}' -f
            $duration
        )
        Write-Host "Devices analyzed:      $($recommendations.Count)"
        Write-Host "Assignments proposed:  $($reportSummary.AssignCount)"
        Write-Host "Changes proposed:      $($reportSummary.ChangeCount)"
        Write-Host "Manual reviews:        $($reportSummary.ReviewCount)"
        Write-Host "No changes required:   $($reportSummary.NoChangeCount)"
        Write-Host "No evidence:           $($reportSummary.NoEvidenceCount)"
        Write-Host ''
        Write-Host 'No Intune assignments were modified.'
        Write-Host ''

        if ($PassThru) {
            return [pscustomobject]@{
                StartedDateTime  = $auditStartTime
                CompletedDateTime = $auditEndTime
                Duration         = $duration
                GraphContext     = $graphContext
                Devices          = $devices
                SignInEvidence   = $signInEvidence
                Recommendations  = $recommendations
                ReportSummary    = $reportSummary
            }
        }
    }
    catch {
        $auditEndTime = Get-Date
        $duration = $auditEndTime - $auditStartTime

        Write-Error (
            'Primary User Audit failed after {0:hh\:mm\:ss}. {1}' -f
            $duration,
            $_.Exception.Message
        )

        throw
    }
}