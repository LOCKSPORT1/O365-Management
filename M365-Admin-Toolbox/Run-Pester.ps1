<#
.SYNOPSIS
    Runs the M365 Admin Toolbox Pester test suite.
.DESCRIPTION
    Ensures Pester is installed, then invokes the toolbox's Pester tests. The default
    test path is resolved relative to this script's location so it works regardless
    of the caller's current working directory.
.PARAMETER TestPath
    Path to the Pester test file or directory to run. Defaults to
    tests\M365AdminToolbox.Tests.ps1 alongside this script.
.EXAMPLE
    .\Run-Pester.ps1

    Runs the default toolbox test suite.
#>
param([string]$TestPath = (Join-Path $PSScriptRoot 'tests\M365AdminToolbox.Tests.ps1'))

if (-not (Get-Module -ListAvailable -Name Pester)) {
    Install-Module -Name Pester -Scope CurrentUser -Force -SkipPublisherCheck
}
Invoke-Pester -Path $TestPath
