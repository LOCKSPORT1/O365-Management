# Modules/O365Toolkit.Teams/Tests/Get-ToolkitTeamUser.Tests.ps1
<#
.SYNOPSIS
    Unit tests for Get-ToolkitTeamUser.
.DESCRIPTION
    Validates parameter binding, role categorization, and endpoint mapping.
#>

# ---------------------------------------------------------------------------
# CHANGE: 2026-08-18 - Unit test suite for Get-ToolkitTeamUser.
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

    $functionScript = Join-Path -Path $repoRoot -ChildPath 'Modules\O365Toolkit.Teams\Public\Get-ToolkitTeamUser.ps1'

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

Describe 'Get-ToolkitTeamUser' {
    BeforeAll {
        Mock Assert-ToolkitGraphConnection { }
        Mock Get-ToolkitGraphUri {
            param([string]$RelativePath, [hashtable]$Config)
            return "https://graph.microsoft.com/$RelativePath"
        }
    }

    Context 'Parameter Validation & Request Building' {
        It 'queries all team members and classifies roles properly' {
            Mock Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id                = 'membership-1'
                        userId            = 'user-guid-1'
                        displayName       = 'Alice Admin'
                        userPrincipalName = 'alice@contoso.com'
                        roles             = @('owner')
                    },
                    [PSCustomObject]@{
                        id                = 'membership-2'
                        userId            = 'user-guid-2'
                        displayName       = 'Bob Member'
                        userPrincipalName = 'bob@contoso.com'
                        roles             = @()
                    }
                )
            } -ParameterFilter {
                $Uri -eq 'https://graph.microsoft.com/v1.0/teams/11111111-2222-3333-4444-555555555555/members'
            }

            $result = Get-ToolkitTeamUser -TeamId '11111111-2222-3333-4444-555555555555'
            $result.Count | Should -Be 2
            $result[0].Role | Should -Be 'owner'
            $result[1].Role | Should -Be 'member'
        }

        It 'filters results by Role owner' {
            Mock Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id                = 'membership-1'
                        userId            = 'user-guid-1'
                        displayName       = 'Alice Admin'
                        userPrincipalName = 'alice@contoso.com'
                        roles             = @('owner')
                    },
                    [PSCustomObject]@{
                        id                = 'membership-2'
                        userId            = 'user-guid-2'
                        displayName       = 'Bob Member'
                        userPrincipalName = 'bob@contoso.com'
                        roles             = @()
                    }
                )
            }

            $result = Get-ToolkitTeamUser -TeamId '11111111-2222-3333-4444-555555555555' -Role 'owner'
            $result.Count | Should -Be 1
            $result[0].DisplayName | Should -Be 'Alice Admin'
            $result[0].Role | Should -Be 'owner'
        }
    }
}