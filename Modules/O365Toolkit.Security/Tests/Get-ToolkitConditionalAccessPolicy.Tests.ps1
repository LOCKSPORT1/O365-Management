# Modules/O365Toolkit.Security/Tests/Get-ToolkitConditionalAccessPolicy.Tests.ps1
<#
.SYNOPSIS
    Unit tests for Get-ToolkitConditionalAccessPolicy.
.DESCRIPTION
    Validates parameter binding, Graph API endpoint construction, filter escaping,
    and output mapping using mock isolation compatible with Pester v5 and v6.
#>

# ---------------------------------------------------------------------------
# CHANGE: 2026-08-18 - Initial creation of Get-ToolkitConditionalAccessPolicy unit tests.
# Module: O365Toolkit.Security
# Track: NEUTRAL
# ---------------------------------------------------------------------------

BeforeAll {
    $repoRoot = $PSScriptRoot
    while ($repoRoot -and -not (Test-Path -Path (Join-Path -Path $repoRoot -ChildPath '.git'))) {
        $parent = [System.IO.Path]::GetDirectoryName($repoRoot)
        if ($parent -eq $repoRoot) { break }
        $repoRoot = $parent
    }

    $functionScript = Join-Path -Path $repoRoot -ChildPath 'Modules\O365Toolkit.Security\Public\Get-ToolkitConditionalAccessPolicy.ps1'

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

Describe 'Get-ToolkitConditionalAccessPolicy' {
    BeforeAll {
        Mock Assert-ToolkitGraphConnection { }
        Mock Get-ToolkitGraphUri {
            param([string]$RelativePath, [hashtable]$Config)
            return "https://graph.microsoft.com/$RelativePath"
        }
    }

    Context 'Parameter Validation & Request Building' {
        It 'queries all Conditional Access policies via Graph endpoint' {
            Mock Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id          = 'cap-00000000-0000-0000-0000-000000000001'
                        displayName = 'Require MFA for Admins'
                        state       = 'enabled'
                    }
                )
            } -ParameterFilter {
                $Uri -like '*v1.0/identity/conditionalAccess/policies*'
            }

            $result = Get-ToolkitConditionalAccessPolicy
            $result | Should -Not -BeNullOrEmpty
            $result.DisplayName | Should -Be 'Require MFA for Admins'
            $result.State | Should -Be 'enabled'
        }

        It 'queries a specific policy by PolicyId' {
            Mock Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id          = 'cap-00000000-0000-0000-0000-000000000001'
                    displayName = 'Block Legacy Authentication'
                    state       = 'enabled'
                }
            } -ParameterFilter {
                $Uri -eq 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/cap-00000000-0000-0000-0000-000000000001'
            }

            $result = Get-ToolkitConditionalAccessPolicy -PolicyId 'cap-00000000-0000-0000-0000-000000000001'
            $result | Should -Not -BeNullOrEmpty
            $result.DisplayName | Should -Be 'Block Legacy Authentication'
        }

        It 'applies State filter correctly' {
            Mock Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id          = 'cap-00000000-0000-0000-0000-000000000002'
                        displayName = 'Report-Only MFA'
                        state       = 'enabledForReportingButNotEnforced'
                    }
                )
            } -ParameterFilter {
                $Uri -like '*state%20eq%20%27enabledForReportingButNotEnforced%27*'
            }

            $result = Get-ToolkitConditionalAccessPolicy -State 'enabledForReportingButNotEnforced'
            $result.State | Should -Be 'enabledForReportingButNotEnforced'
        }
    }
}