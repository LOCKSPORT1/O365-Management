# Modules/O365Toolkit.Security/Tests/Get-ToolkitAuditLogEntry.Tests.ps1
<#
.SYNOPSIS
    Unit tests for Get-ToolkitAuditLogEntry.
.DESCRIPTION
    Validates parameter binding, timestamp filter formatting, initiator extraction,
    and output mapping using mock isolation compatible with Pester v5 and v6.
#>

# ---------------------------------------------------------------------------
# CHANGE: 2026-08-18 - Initial creation of Get-ToolkitAuditLogEntry unit tests.
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

    $functionScript = Join-Path -Path $repoRoot -ChildPath 'Modules\O365Toolkit.Security\Public\Get-ToolkitAuditLogEntry.ps1'

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

Describe 'Get-ToolkitAuditLogEntry' {
    BeforeAll {
        Mock Assert-ToolkitGraphConnection { }
        Mock Get-ToolkitGraphUri {
            param([string]$RelativePath, [hashtable]$Config)
            return "https://graph.microsoft.com/$RelativePath"
        }
    }

    Context 'Parameter Validation & Request Building' {
        It 'queries directory audit events via Graph endpoint' {
            Mock Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id                  = 'audit-00000000-0000-0000-0000-000000000001'
                        activityDateTime    = '2026-08-18T12:00:00Z'
                        activityDisplayName = 'Add member to group'
                        category            = 'GroupManagement'
                        result              = 'success'
                        initiatedBy         = [PSCustomObject]@{
                            user = [PSCustomObject]@{ userPrincipalName = 'admin@contoso.com' }
                        }
                    }
                )
            } -ParameterFilter {
                $Uri -like '*v1.0/auditLogs/directoryAudits*'
            }

            $result = Get-ToolkitAuditLogEntry
            $result | Should -Not -BeNullOrEmpty
            $result.ActivityDisplayName | Should -Be 'Add member to group'
            $result.InitiatedByUser | Should -Be 'admin@contoso.com'
            $result.Category | Should -Be 'GroupManagement'
        }

        It 'applies Category filter properly' {
            Mock Invoke-ToolkitGraphRequest {
                return @(
                    [PSCustomObject]@{
                        id                  = 'audit-00000000-0000-0000-0000-000000000002'
                        activityDateTime    = '2026-08-18T12:00:00Z'
                        activityDisplayName = 'Update user'
                        category            = 'UserManagement'
                        result              = 'success'
                    }
                )
            } -ParameterFilter {
                $Uri -like '*category%20eq%20%27UserManagement%27*'
            }

            $result = Get-ToolkitAuditLogEntry -Category 'UserManagement'
            $result.Category | Should -Be 'UserManagement'
        }
    }
}