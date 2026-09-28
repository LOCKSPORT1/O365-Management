<#
    Menu manifest - M365-Admin-Toolbox access-profile scripts

    Drives Start-ScriptMenu.ps1, which lives beside this file. Read with
    Import-PowerShellDataFile, so literal data only.

    The curated shortcuts below name the guided paths; everything else in the
    folder still appears in the numbered list. Parameters are discovered from
    each script's own param block, so nothing here needs updating when a script
    gains a parameter.
#>
@{

    Title   = 'M365 Admin Toolbox - access profile'

    Root    = '.'

    Reports = 'Reports'

    LogPath = 'Logs\launcher.jsonl'

    Notice  = 'Copy environment.example.psd1 to environment.psd1 and fill it in before first use.'

    Discovery = @{
        Mode    = 'Files'
        Recurse = $false

        # Workers and menu plumbing are not runnable entries.
        Exclude = @(
            '_*.ps1'
            '*.Tests.ps1'
            'Start-ScriptMenu.ps1'
        )
    }

    DryRunNames = @('WhatIfMode', 'WhatIf', 'Preview', 'DryRun')

    RedactParameters = @('Password', 'Secret', 'Credential', 'Token', 'ClientSecret')

    Sections = @(

        @{
            Name  = 'LIFECYCLE'
            Note  = 'guided - recommended'
            Items = @(
                @{
                    Key     = 'O'
                    Label   = 'Onboard a new user'
                    Command = 'New-UserFromAccessProfile'
                    Mode    = 'Ask'
                    Note    = 'name prompts, then pick an access profile'
                }
                @{
                    Key     = 'F'
                    Label   = 'Offboard a user'
                    Command = 'Offboard-HybridUser'
                    Mode    = 'Ask'
                    Confirm = $true
                    Note    = 'confirmation gate, then the full pipeline'
                }
                @{
                    Key     = 'X'
                    Label   = 'Export an access profile'
                    Command = 'Export-UserAccessProfile'
                    Mode    = 'Live'
                    ReadOnly = $true
                    Note    = 'run against a template user, not a leaver'
                }
            )
        }

        @{
            Name  = 'HELPDESK'
            Items = @(
                @{
                    Key     = 'P'
                    Label   = 'Reset a password'
                    Command = 'Reset-UserPassword'
                    Mode    = 'Ask'
                    Note    = 'unlocks too; asks about change-at-next-logon'
                }
                @{
                    Key     = 'D'
                    Label   = 'Repair device primary user'
                    Command = 'Repair-DevicePrimaryUser'
                    Mode    = 'Ask'
                    Note    = 'clears a stale Intune primary user'
                }
            )
        }

        @{
            Name  = 'AUDIT'
            Note  = 'read-only'
            Items = @(
                @{
                    Key      = 'G'
                    Label    = 'Group membership'
                    Command  = 'Audit-GroupMembership'
                    Mode     = 'Live'
                    ReadOnly = $true
                    Note     = 'changes nothing'
                }
                @{
                    Key      = 'M'
                    Label    = 'Shared mailbox OU'
                    Command  = 'Audit-SharedMailboxOU'
                    Mode     = 'Live'
                    ReadOnly = $true
                    Note     = 'mailboxes outside the configured OU'
                }
                @{
                    Key      = 'I'
                    Label    = 'Dynamic group inactive filter'
                    Command  = 'Audit-DynamicGroupInactiveFilter'
                    Mode     = 'Live'
                    ReadOnly = $true
                    Note     = 'rules that do not exclude disabled accounts'
                }
            )
        }
    )
}
