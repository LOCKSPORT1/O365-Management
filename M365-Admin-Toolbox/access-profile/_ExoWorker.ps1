<#
.SYNOPSIS
    Exchange Online worker - runs in an isolated child process.

.DESCRIPTION
    ExchangeOnlineManagement and Microsoft.Graph.Authentication ship different builds of
    Microsoft.IdentityModel.Abstractions (EXO 3.10.1 -> 8.19.2.0, Graph 2.39.0 -> 8.18.0.0).
    .NET permits only ONE version of an assembly per load context per process, and the first
    module to load it wins. MSAL's WithLogging(IIdentityLogger, Boolean) overload carries the
    Abstractions type identity in its signature, so once EXO has pinned 8.19.2.0 any
    Connect-MgGraph in the same process fails with:

        Method not found: '!0 Microsoft.Identity.Client.BaseAbstractApplicationBuilder`1
          .WithLogging(Microsoft.IdentityModel.Abstractions.IIdentityLogger, Boolean)'

    There is no combination of current EXO / Graph releases where these align, so version
    matching cannot fix it. This worker keeps Exchange in its own process: the parent script
    holds the Graph session and never imports EXO, this child imports EXO and never touches
    Graph. Neither shares a load context with the other.

    Called by Offboard-HybridUser.ps1 via Invoke-ExoTask. Not intended to be run
    directly, though it is safe to do so for troubleshooting.

.PARAMETER TaskFile
    JSON file describing the work to do. See the Tasks region below for the shape.

.PARAMETER ResultFile
    JSON file this script writes its results to. Each record matches the parent's Add-Result
    columns: Stage, Item, Action, Status, Detail.

.PARAMETER DisableWAM
    Pass -DisableWAM through to Connect-ExchangeOnline. On by default from the parent: the
    Windows Web Account Manager broker throws a NullReferenceException in
    RuntimeBroker..ctor under pwsh -NoProfile -File launched from a UNC path, which is how
    the toolkit runs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$TaskFile,
    [Parameter(Mandatory)] [string]$ResultFile,
    [switch]$DisableWAM,
    [switch]$WhatIfMode
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[Object]

function Add-WorkerResult {
    param($Stage, $Item, $Action, $Status, $Detail = '')
    $results.Add([PSCustomObject]@{
        Stage  = $Stage
        Item   = $Item
        Action = $Action
        Status = $Status
        Detail = $Detail
    })
}

function Save-Results {
    # Always write something, even on catastrophic failure - the parent treats a missing
    # result file as "the worker died" and reports that, but a written file with a Failed
    # record is far more useful than a bare exit code.
    try {
        $json = if ($results.Count) { $results | ConvertTo-Json -Depth 5 -AsArray } else { '[]' }
        Set-Content -LiteralPath $ResultFile -Value $json -Encoding UTF8
    }
    catch {
        Write-Warning "Could not write result file '$ResultFile': $($_.Exception.Message)"
    }
}

try {
    $task = Get-Content -LiteralPath $TaskFile -Raw | ConvertFrom-Json
}
catch {
    Add-WorkerResult 'Exchange' 'n/a' 'Read task file' 'Failed' $_.Exception.Message
    Save-Results
    exit 1
}

#region Connect
try {
    Import-Module ExchangeOnlineManagement -ErrorAction Stop

    $connectArgs = @{ ShowBanner = $false; ErrorAction = 'Stop' }
    if ($DisableWAM) {
        # -DisableWAM only exists on newer EXO builds. Probe rather than assume, so an older
        # module degrades to a normal connect instead of failing on an unknown parameter.
        $cmd = Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Parameters.ContainsKey('DisableWAM')) {
            $connectArgs['DisableWAM'] = $true
        }
    }

    Write-Host "  [Exchange] Connecting to Exchange Online..." -ForegroundColor Cyan
    Connect-ExchangeOnline @connectArgs
    Write-Host "  [Exchange] Connected." -ForegroundColor DarkGray
}
catch {
    Add-WorkerResult 'Exchange' 'n/a' 'Connect-ExchangeOnline' 'Failed' $_.Exception.Message
    Save-Results
    exit 1
}
#endregion

#region Tasks
foreach ($op in @($task.Operations)) {
    switch ($op.Type) {

        # ------------------------------------------------------------------
        # ConvertMailbox: Upn, ManagerUpn (optional), AutoMapping (bool)
        # ------------------------------------------------------------------
        'ConvertMailbox' {
            $upn = $op.Upn
            try {
                $mbx = Get-Mailbox -Identity $upn -ErrorAction SilentlyContinue
                if (-not $mbx) {
                    Add-WorkerResult 'Exchange' $upn 'Convert to Shared Mailbox' 'Skipped' 'No mailbox found for user'
                    break
                }

                if ($WhatIfMode) {
                    Add-WorkerResult 'Exchange' $upn 'Convert to Shared Mailbox' 'Skipped' 'WhatIf - no change made'
                }
                else {
                    Set-Mailbox -Identity $upn -Type Shared -ErrorAction Stop
                    Add-WorkerResult 'Exchange' $upn 'Convert to Shared Mailbox' 'Success'
                }

                # Grant the manager Full Access so the mailbox is actually reachable.
                # AutoMapping is off by default - it force-mounts the mailbox in the manager's
                # Outlook profile, which is often unwanted on a departed employee's mailbox.
                if ($op.ManagerUpn) {
                    if ($WhatIfMode) {
                        Add-WorkerResult 'Exchange' $upn 'Add-MailboxPermission (FullAccess)' 'Skipped' `
                            "WhatIf - would grant $($op.ManagerUpn)"
                    }
                    else {
                        try {
                            Add-MailboxPermission -Identity $upn -User $op.ManagerUpn `
                                -AccessRights FullAccess -InheritanceType All `
                                -AutoMapping:([bool]$op.AutoMapping) -Confirm:$false -ErrorAction Stop | Out-Null
                            Add-WorkerResult 'Exchange' $upn 'Add-MailboxPermission (FullAccess)' 'Success' `
                                "$($op.ManagerUpn) (AutoMapping=$([bool]$op.AutoMapping))"
                        }
                        catch {
                            Add-WorkerResult 'Exchange' $upn 'Add-MailboxPermission (FullAccess)' 'Failed' `
                                "$($op.ManagerUpn) - $($_.Exception.Message)"
                        }
                    }
                }
                else {
                    Add-WorkerResult 'Exchange' $upn 'Add-MailboxPermission (FullAccess)' 'Warning' `
                        'No manager known - mailbox is shared but nobody has been granted access. Re-run with -ManagerUpn, or grant access manually.'
                }
            }
            catch {
                Add-WorkerResult 'Exchange' $upn 'Convert to Shared Mailbox' 'Failed' $_.Exception.Message
            }
        }

        # ------------------------------------------------------------------
        # RemoveDistributionGroupMembers: Upn, Groups[] of { GroupId, GroupName }
        # ------------------------------------------------------------------
        'RemoveDistributionGroupMembers' {
            $upn = $op.Upn
            foreach ($g in @($op.Groups)) {
                if ($WhatIfMode) {
                    Add-WorkerResult 'Entra-Groups' $g.GroupName 'Remove-DistributionGroupMember (EXO)' 'Skipped' `
                        "WhatIf - would remove from GroupId $($g.GroupId)"
                    continue
                }
                try {
                    # -Identity by GROUP ID, not display name: display names are not unique in
                    # Exchange (this tenant has two groups sharing a name), so a name-based
                    # removal can hit the wrong group or fail as ambiguous. EXO accepts the
                    # Entra object ID as ExternalDirectoryObjectId.
                    Remove-DistributionGroupMember -Identity $g.GroupId -Member $upn `
                        -Confirm:$false -BypassSecurityGroupManagerCheck -ErrorAction Stop
                    Add-WorkerResult 'Entra-Groups' $g.GroupName 'Remove-DistributionGroupMember (EXO)' 'Success' `
                        "GroupId $($g.GroupId)"
                }
                catch {
                    Add-WorkerResult 'Entra-Groups' $g.GroupName 'Remove-DistributionGroupMember (EXO)' 'Failed' `
                        $_.Exception.Message
                }
            }
        }

        default {
            Add-WorkerResult 'Exchange' 'n/a' "Unknown task type '$($op.Type)'" 'Failed' `
                'The parent script asked for an operation this worker does not implement - version mismatch between Offboard-HybridUser.ps1 and _ExoWorker.ps1?'
        }
    }
}
#endregion

#region Disconnect
try {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}
catch { }
#endregion

Save-Results
exit 0
