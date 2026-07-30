function Disconnect-ToolkitGraph {
    <#
    .SYNOPSIS
        Disconnects the toolkit from Microsoft Graph.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Config,

        [Parameter()]
        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $component = 'GraphAuthentication'

    $context = $null

    if (Get-Command Get-MgContext -ErrorAction SilentlyContinue) {
    try {
        $context = Get-MgContext -ErrorAction Stop
    }
    catch {
        if (
            $_.FullyQualifiedErrorId -match 'SessionNotInitialized' -or
            $_.Exception.Message -match 'SessionNotInitialized'
        ) {
            $context = $null
        }
        else {
            throw
        }
    }
}

    if (-not $context) {
        Write-ToolkitLog `
            -Config $Config `
            -Level Information `
            -Component $component `
            -Message 'No active Microsoft Graph connection was found.'

        $result = [pscustomobject]@{
            PSTypeName      = 'O365Toolkit.GraphDisconnectResult'
            Success         = $true
            WasConnected    = $false
            DisconnectedAt  = Get-Date
            PreviousAccount = $null
            PreviousTenantId = $null
        }

        if ($PassThru) {
            return $result
        }

        return
    }

    $previousAccount = $context.Account
    $previousTenantId = $context.TenantId

    Disconnect-MgGraph -ErrorAction Stop | Out-Null

    Write-ToolkitLog `
        -Config $Config `
        -Level Information `
        -Component $component `
        -Message (
            'Disconnected Microsoft Graph account {0}.' -f
            $previousAccount
        )

    $result = [pscustomobject]@{
        PSTypeName       = 'O365Toolkit.GraphDisconnectResult'
        Success          = $true
        WasConnected     = $true
        DisconnectedAt   = Get-Date
        PreviousAccount  = $previousAccount
        PreviousTenantId = $previousTenantId
    }

    if ($PassThru) {
        return $result
    }
}
