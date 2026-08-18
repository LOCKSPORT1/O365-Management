# Modules/O365Toolkit.SharePoint/Tests/Get-ToolkitSharePointSite.Tests.ps1
<#
.SYNOPSIS
    Unit tests for Get-ToolkitSharePointSite.
.DESCRIPTION
    Validates parameter binding, Graph API endpoint construction, root site lookup,
    and output mapping using mock isolation compatible with Pester v5 and v6.
#>

# ---------------------------------------------------------------------------
# CHANGE: 2026-08-18 - Initial creation of Get-ToolkitSharePointSite unit tests.
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

    $functionScript = Join-Path -Path $repoRoot -ChildPath 'Modules\O365Toolkit.SharePoint\Public\Get-ToolkitSharePointSite.ps1'

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

Describe 'Get-ToolkitSharePointSite' {
    BeforeAll {
        Mock Assert-ToolkitGraphConnection { }
        Mock Get-ToolkitGraphUri {
            param([string]$RelativePath, [hashtable]$Config)
            return "https://graph.microsoft.com/$RelativePath"
        }
    }

    Context 'Parameter Validation & Request Building' {
        It 'queries sites via Graph endpoint with default parameters' {
            Mock Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id          = 'contoso.sharepoint.com,site-guid-1,web-guid-1'
                        displayName = 'Engineering Hub'
                        name        = 'engineering'
                        webUrl      = 'https://contoso.sharepoint.com/sites/engineering'
                    }
                )
            } -ParameterFilter {
                $Uri -like '*v1.0/sites*'
            }

            $result = Get-ToolkitSharePointSite
            $result | Should -Not -BeNullOrEmpty
            $result.DisplayName | Should -Be 'Engineering Hub'
            $result.Name | Should -Be 'engineering'
        }

        It 'queries the root site when -Root switch is passed' {
            Mock Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id          = 'contoso.sharepoint.com,root-guid,web-root-guid'
                    displayName = 'Tenant Root'
                    name        = 'root'
                    webUrl      = 'https://contoso.sharepoint.com'
                }
            } -ParameterFilter {
                $Uri -eq 'https://graph.microsoft.com/v1.0/sites/root'
            }

            $result = Get-ToolkitSharePointSite -Root
            $result | Should -Not -BeNullOrEmpty
            $result.DisplayName | Should -Be 'Tenant Root'
            $result.WebUrl | Should -Be 'https://contoso.sharepoint.com'
        }

        It 'queries a specific site by SiteId' {
            Mock Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id          = 'contoso.sharepoint.com,site-guid-1,web-guid-1'
                    displayName = 'Finance Team Site'
                    webUrl      = 'https://contoso.sharepoint.com/sites/finance'
                }
            } -ParameterFilter {
                $Uri -eq 'https://graph.microsoft.com/v1.0/sites/contoso.sharepoint.com,site-guid-1,web-guid-1'
            }

            $result = Get-ToolkitSharePointSite -SiteId 'contoso.sharepoint.com,site-guid-1,web-guid-1'
            $result.DisplayName | Should -Be 'Finance Team Site'
        }

        It 'applies Search filter correctly' {
            Mock Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id          = 'contoso.sharepoint.com,site-guid-2,web-guid-2'
                        displayName = 'Project Alpha'
                        webUrl      = 'https://contoso.sharepoint.com/sites/projectalpha'
                    }
                )
            } -ParameterFilter {
                $Uri -like '*search=Project*'
            }

            $result = Get-ToolkitSharePointSite -Search 'Project'
            $result.DisplayName | Should -Be 'Project Alpha'
        }
    }
}