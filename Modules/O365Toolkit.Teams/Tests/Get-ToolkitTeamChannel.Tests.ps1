# Modules/O365Toolkit.Teams/Tests/Get-ToolkitTeamChannel.Tests.ps1
<#
.SYNOPSIS
    Unit tests for Get-ToolkitTeamChannel.
.DESCRIPTION
    Validates parameter binding, endpoint construction, and return mapping.
#>

# ---------------------------------------------------------------------------
# CHANGE: 2026-08-18 - Unit test suite for Get-ToolkitTeamChannel.
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

    $functionScript = Join-Path -Path $repoRoot -ChildPath 'Modules\O365Toolkit.Teams\Public\Get-ToolkitTeamChannel.ps1'

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

Describe 'Get-ToolkitTeamChannel' {
    BeforeAll {
        Mock Assert-ToolkitGraphConnection { }
        Mock Get-ToolkitGraphUri {
            param([string]$RelativePath, [hashtable]$Config)
            return "https://graph.microsoft.com/$RelativePath"
        }
    }

    Context 'Parameter Validation & Endpoint Building' {
        It 'queries all channels for a given TeamId' {
            Mock Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id             = '19:general@thread.tacv2'
                        displayName    = 'General'
                        description    = 'General channel'
                        membershipType = 'standard'
                    },
                    [PSCustomObject]@{
                        id             = '19:private@thread.tacv2'
                        displayName    = 'Leadership'
                        description    = 'Private leadership channel'
                        membershipType = 'private'
                    }
                )
            } -ParameterFilter {
                $Uri -eq 'https://graph.microsoft.com/v1.0/teams/11111111-2222-3333-4444-555555555555/channels'
            }

            $result = Get-ToolkitTeamChannel -TeamId '11111111-2222-3333-4444-555555555555'
            $result.Count | Should -Be 2
            $result[0].DisplayName | Should -Be 'General'
            $result[1].MembershipType | Should -Be 'private'
        }

        It 'queries a specific channel by ChannelId' {
            Mock Invoke-ToolkitGraphRequest {
                return [PSCustomObject]@{
                    id             = '19:general@thread.tacv2'
                    displayName    = 'General'
                    membershipType = 'standard'
                }
            } -ParameterFilter {
                $Uri -eq 'https://graph.microsoft.com/v1.0/teams/11111111-2222-3333-4444-555555555555/channels/19:general@thread.tacv2'
            }

            $result = Get-ToolkitTeamChannel -TeamId '11111111-2222-3333-4444-555555555555' -ChannelId '19:general@thread.tacv2'
            $result.DisplayName | Should -Be 'General'
            $result.TeamId | Should -Be '11111111-2222-3333-4444-555555555555'
        }
    }
}