<#
.SYNOPSIS
    Batch onboarding from a CSV (typical HR export format) - runs
    New-M365UserOnboarding.ps1 once per row instead of doing new hires
    one at a time. The classic "we just hired 12 seasonal warehouse
    staff, here's a spreadsheet" scenario.

.DESCRIPTION
    Expects a CSV with columns: FirstName, LastName, JobTitle, Department,
    ManagerUpn (matches the parameters New-M365UserOnboarding.ps1 already
    takes). Runs each row through that existing script sequentially,
    collects results, and gives you one consolidated summary + a CSV of
    generated temp passwords to hand off securely instead of copy-pasting
    output from a scrolling console per user.

.PARAMETER CsvPath
    Path to the input CSV. Must contain columns: FirstName, LastName,
    JobTitle, Department, ManagerUpn.

.PARAMETER Mode
    CloudOnly or HybridSync - passed through to New-M365UserOnboarding.ps1
    for each row. Defaults to HybridSync.

.PARAMETER CredentialExportPath
    Path to write the consolidated results/temp-password handoff CSV to.

.EXAMPLE
    .\New-BulkUserImportFromCsv.ps1 -CsvPath "C:\HR\NewHires.csv" -Mode HybridSync

.EXAMPLE
    .\New-BulkUserImportFromCsv.ps1 -CsvPath "C:\HR\NewHires.csv" -Mode CloudOnly -CredentialExportPath "C:\Secure\Handoff.csv"

.NOTES
    This is a thin orchestration wrapper - it doesn't duplicate onboarding
    logic, it calls 01-Onboarding\New-M365UserOnboarding.ps1 per row.
    Requires that script (and its dependencies) to be present relative to
    this one, or adjust $OnboardingScriptPath below. One malformed/failing
    row does not abort the batch - each row is wrapped in its own
    try/catch and failures are reported in the end-of-run summary.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [ValidateSet("CloudOnly","HybridSync")]
    [string]$Mode = "HybridSync",
    [string]$CredentialExportPath = ".\BulkOnboarding_Credentials_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Path to the onboarding script this wrapper calls once per CSV row.
$OnboardingScriptPath = "$PSScriptRoot\..\01-Onboarding\New-M365UserOnboarding.ps1"

# CSV columns required to process a row.
$RequiredCsvColumns = @("FirstName","LastName","JobTitle","Department","ManagerUpn")

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV not found at $CsvPath"
    return
}
if (-not (Test-Path $OnboardingScriptPath)) {
    Write-Error "Cannot find New-M365UserOnboarding.ps1 at $OnboardingScriptPath - adjust `$OnboardingScriptPath at the top of this script."
    return
}

$rows = Import-Csv $CsvPath
if (-not $rows -or $rows.Count -eq 0) {
    Write-Error "CSV at $CsvPath contains no data rows."
    return
}

$missingCols = $RequiredCsvColumns | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
if ($missingCols) {
    Write-Error "CSV is missing required column(s): $($missingCols -join ', ')"
    return
}

Write-Host "Processing $($rows.Count) new hire(s) from $CsvPath in $Mode mode..." -ForegroundColor Cyan

$results = foreach ($row in $rows) {
    Write-Host "`n--- $($row.FirstName) $($row.LastName) ---" -ForegroundColor Yellow

    # Per-row validation: required columns can be present but blank on a given row.
    $blankFields = $RequiredCsvColumns | Where-Object { [string]::IsNullOrWhiteSpace($row.$_) }
    if ($blankFields) {
        Write-Warning "Skipping row - blank required field(s): $($blankFields -join ', ')"
        [PSCustomObject]@{
            FirstName    = $row.FirstName
            LastName     = $row.LastName
            UPN          = "N/A"
            TempPassword = "N/A"
            Status       = "FAILED: blank required field(s): $($blankFields -join ', ')"
        }
        continue
    }

    $transcriptPath = [System.IO.Path]::GetTempFileName()
    $transcriptStarted = $false
    try {
        # Capture the transcript so we can pull the generated temp password out of console output
        Start-Transcript -Path $transcriptPath -Force | Out-Null
        $transcriptStarted = $true

        & $OnboardingScriptPath -FirstName $row.FirstName -LastName $row.LastName `
            -JobTitle $row.JobTitle -Department $row.Department -ManagerUpn $row.ManagerUpn -Mode $Mode

        Stop-Transcript | Out-Null
        $transcriptStarted = $false
        $transcript = Get-Content $transcriptPath -Raw

        $tempPwdMatch = [regex]::Match($transcript, "Temp(?:orary)? password:\s*(\S+)")
        $upnMatch = [regex]::Match($transcript, "UPN:\s*(\S+)")

        [PSCustomObject]@{
            FirstName    = $row.FirstName
            LastName     = $row.LastName
            UPN          = if ($upnMatch.Success) { $upnMatch.Groups[1].Value } else { "UNKNOWN - check console output" }
            TempPassword = if ($tempPwdMatch.Success) { $tempPwdMatch.Groups[1].Value } else { "UNKNOWN - check console output" }
            Status       = "Success"
        }
    }
    catch {
        [PSCustomObject]@{
            FirstName    = $row.FirstName
            LastName     = $row.LastName
            UPN          = "N/A"
            TempPassword = "N/A"
            Status       = "FAILED: $_"
        }
    }
    finally {
        # Make sure a failed row never leaves a transcript running (would break the next row's Start-Transcript).
        if ($transcriptStarted) {
            try { Stop-Transcript | Out-Null } catch {}
        }
        Remove-Item $transcriptPath -ErrorAction SilentlyContinue
    }
}

$results | Export-Csv -Path $CredentialExportPath -NoTypeInformation
Write-Host "`n=== Bulk onboarding summary ===" -ForegroundColor Cyan
$results | Format-Table FirstName, LastName, UPN, Status -AutoSize
Write-Host "Credential export (handle securely, delete after handoff): $CredentialExportPath" -ForegroundColor Yellow

$failures = $results | Where-Object { $_.Status -ne "Success" }
if ($failures) {
    Write-Host "`n$($failures.Count) failure(s) - review and re-run those rows individually." -ForegroundColor Red
}
