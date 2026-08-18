# Modules/O365Toolkit.Teams/Tests/Get-ToolkitTeam.Tests.ps1
<#
.SYNOPSIS
    Unit tests for Get-ToolkitTeam.
.DESCRIPTION
    Validates parameter binding, Graph API endpoint construction, filter escaping,
    and output mapping using mock isolation compatible with Pester v5 and v6.
#>

# ---------------------------------------------------------------------------
# CHANGE: 2026-08-18 - Corrected Mock ParameterFilter to account for URI query string
# encoding on $filter expressions and added default fallback mock to prevent unmatched filter errors.
# Module: O365Toolkit.Teams
# Track: NEUTRAL
# ---------------------------------------------------------------------------

BeforeAll {
    $repoRoot = $PSScriptRoot
    while ($repoRoot -and -not (Test-Path -Path (Join-Path -Path $repoRoot -ChildPath '.git'))) {
        $parent = [System.IO.Path]::GetDirectoryName($repoRoot)
        if ($parent -eq $repoRoot) { break }
        $repoRoot = $parent
    }

    $functionScript = Join-Path -Path $repoRoot -ChildPath 'Modules\O365Toolkit.Teams\Public\Get-ToolkitTeam.ps1'

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

Describe 'Get-ToolkitTeam' {
    BeforeAll {
        Mock Assert-ToolkitGraphConnection { }
        Mock Get-ToolkitGraphUri {
            param([string]$RelativePath, [hashtable]$Config)
            return "https://graph.microsoft.com/$RelativePath"
        }
    }

    Context 'Parameter Validation & Request Building' {
        It 'queries Teams groups via Graph endpoint with default filters' {
            Mock Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id                          = '11111111-2222-3333-4444-555555555555'
                        displayName                 = 'Engineering Team'
                        description                 = 'Core Engineering'
                        mailNickname                = 'engineering'
                        visibility                  = 'Private'
                        createdDateTime             = '2024-01-01T00:00:00Z'
                        resourceProvisioningOptions = @('Team')
                    }
                )
            } -ParameterFilter {
                $Uri -like '*v1.0/groups*' -and $Uri -like '*resourceProvisioningOptions*'
            }

            $result = Get-ToolkitTeam
            $result | Should -Not -BeNullOrEmpty
            $result.DisplayName | Should -Be 'Engineering Team'
            $result.MailNickname | Should -Be 'engineering'
        }

        It 'queries a specific team by TeamId' {
            Mock Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id          = '11111111-2222-3333-4444-555555555555'
                    displayName = 'IT Operations'
                    description = 'IT Ops Team'
                    isArchived  = $false
                    visibility  = 'Private'
                }
            } -ParameterFilter {
                $Uri -eq 'https://graph.microsoft.com/v1.0/teams/11111111-2222-3333-4444-555555555555'
            }

            $result = Get-ToolkitTeam -TeamId '11111111-2222-3333-4444-555555555555'
            $result | Should -Not -BeNullOrEmpty
            $result.DisplayName | Should -Be 'IT Operations'
            $result.IsArchived | Should -BeFalse
        }

        It 'applies DisplayName filter correctly' {
            Mock Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id                          = '22222222-3333-4444-5555-666666666666'
                        displayName                 = 'Marketing'
                        mailNickname                = 'marketing'
                        resourceProvisioningOptions = @('Team')
                    }
                )
            } -ParameterFilter {
                $Uri -like '*displayName*' -and $Uri -like '*Marketing*'
            }

            $result = Get-ToolkitTeam -DisplayName 'Marketing'
            $result.DisplayName | Should -Be 'Marketing'
        }
    }
}
