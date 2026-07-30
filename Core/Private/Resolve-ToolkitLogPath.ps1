function Resolve-ToolkitLogPath {
    <#
    .SYNOPSIS
        Resolves the destination path for a toolkit log file.

    .DESCRIPTION
        Uses the configured log directory and daily-log setting to construct
        the full path to the active toolkit log file.

        This is a private Core module helper.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [psobject]$Config,

        [Parameter()]
        [datetime]$Timestamp = (Get-Date)
    )

    Set-StrictMode -Version Latest

    if (
        $Config.PSObject.Properties.Name -notcontains 'Paths' -or
        $null -eq $Config.Paths
    ) {
        throw 'The configuration object is missing the Paths section.'
    }

    if (
        $Config.Paths.PSObject.Properties.Name -notcontains 'LogDirectory'
    ) {
        throw 'The configuration object is missing Paths.LogDirectory.'
    }

    $logDirectory = [string]$Config.Paths.LogDirectory

    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        throw 'Paths.LogDirectory cannot be empty.'
    }

    $dailyLogFiles = $true

    if (
        $Config.PSObject.Properties.Name -contains 'Logging' -and
        $null -ne $Config.Logging -and
        $Config.Logging.PSObject.Properties.Name -contains 'DailyLogFiles'
    ) {
        $dailyLogFiles = [bool]$Config.Logging.DailyLogFiles
    }

    if ($dailyLogFiles) {
        $fileName =
            'O365Toolkit-{0}.log' -f
            $Timestamp.ToString('yyyy-MM-dd')
    }
    else {
        $fileName = 'O365Toolkit.log'
    }

    return Join-Path -Path $logDirectory -ChildPath $fileName
}
