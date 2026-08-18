# Modules/O365Toolkit.SharePoint/Tests/Get-ToolkitSharePointUsage.Tests.ps1
<#
.SYNOPSIS
    Unit tests for Get-ToolkitSharePointUsage.
.DESCRIPTION
    Validates parameter binding, quota calculations, and output mapping.
#>

# ---------------------------------------------------------------------------
# CHANGE: 2026-08-18 - Initial creation of Get-ToolkitSharePointUsage unit tests.
# Module: O365Toolkit.SharePoint
# Track: NEUTRAL
# ---------------------------------------------------------------------------

BeforeAll {
    $repoRoot = $PSScriptRoot
    while ($repoRoot -and -not (Test-Path -Path (Join-Path -Path $repoRoot -ChildPath '.git'))) {
        $parent = [System.IO.Path]::GetDirectoryName($repoRoot)
        if ($parent -eq $repoRoot) { break }
        $repoRoot = $parent
    }

    $functionScript = Join-Path -Path $repoRoot -ChildPath 'Modules\O365Toolkit.SharePoint\Public\Get-ToolkitSharePointUsage.ps1'

    function global:Assert-ToolkitGraphConnection { }
    function global:Get-ToolkitGraphUri {
        param([string]$RelativePath, [hashtable]$Config)
        return "https://graph.microsoft.com/$RelativePath"
    }
    function global:Invoke-ToolkitGraphRequest {
        param([string]$Uri, [string]$Method, [switch]$AllPages, [hashtable]$Config)
    }

    . $functionScript
}

Describe 'Get-ToolkitSharePointUsage' {
    BeforeAll {
        Mock Assert-ToolkitGraphConnection { }
        Mock Get-ToolkitGraphUri {
            param([string]$RelativePath, [hashtable]$Config)
            return "https://graph.microsoft.com/$RelativePath"
        }
    }

    Context 'Parameter Validation & Quota Calculations' {
        It 'queries drives and converts byte quotas into megabytes correctly' {
            Mock Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id        = 'drive-001'
                        name      = 'Documents'
                        driveType = 'documentLibrary'
                        quota     = [PSCustomObject]@{
                            total     = 107374182400 # 100 GB
                            used      = 26843545600  # 25 GB
                            remaining = 80530636800  # 75 GB
                            state     = 'normal'
                        }
                        webUrl    = 'https://contoso.sharepoint.com/sites/eng/Shared%20Documents'
                    }
                )
            } -ParameterFilter {
                $Uri -eq 'https://graph.microsoft.com/v1.0/sites/site-123/drives'
            }

            $result = Get-ToolkitSharePointUsage -SiteId 'site-123'
            $result | Should -Not -BeNullOrEmpty
            $result.DriveName | Should -Be 'Documents'
            $result.UsedMB | Should -Be 25600
            $result.TotalMB | Should -Be 102400
            $result.PercentUsed | Should -Be 25
            $result.DriveState | Should -Be 'normal'
        }
    }
}