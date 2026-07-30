function Write-ToolkitLog {
    <#
    .SYNOPSIS
        Writes a standardized O365 Management Toolkit log entry.

    .DESCRIPTION
        Writes a timestamped log entry according to the supplied toolkit
        configuration.

        Logging can be sent to the console, a file, or both. Entries below the
        configured minimum level are filtered.

        The function does not write pipeline output unless PassThru is used.

    .PARAMETER Message
        Text to include in the log entry.

    .PARAMETER Config
        Configuration object returned by Read-ToolkitConfig, or a compatible
        object containing Paths and Logging sections.

    .PARAMETER Level
        Severity level of the log entry.

        Supported values are Debug, Information, Warning, and Error.

    .PARAMETER Component
        Name of the module, command, or component generating the entry.

    .PARAMETER Timestamp
        Timestamp assigned to the entry. Defaults to the current date and time.

    .PARAMETER PassThru
        Returns a structured log-result object.

    .EXAMPLE
        $config =
            Read-ToolkitConfig `
                -Path '.\config\toolkit.example.json'

        Write-ToolkitLog `
            -Config $config `
            -Level Information `
            -Component 'PrimaryUserAudit' `
            -Message 'Primary-user audit started.'

    .EXAMPLE
        $result =
            Write-ToolkitLog `
                -Config $config `
                -Level Error `
                -Message 'Graph request failed.' `
                -PassThru
    #>

    [CmdletBinding()]
    param(
        [Parameter(
            Mandatory,
            Position = 0
        )]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [psobject]$Config,

        [Parameter()]
        [ValidateSet(
            'Debug',
            'Information',
            'Warning',
            'Error'
        )]
        [string]$Level = 'Information',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Component = 'General',

        [Parameter()]
        [datetime]$Timestamp = (Get-Date),

        [Parameter()]
        [switch]$PassThru
    )

    Set-StrictMode -Version Latest

    if (
        $Config.PSObject.Properties.Name -notcontains 'Logging' -or
        $null -eq $Config.Logging
    ) {
        throw 'The configuration object is missing the Logging section.'
    }

    $logging = $Config.Logging

    $enabled = $true
    $writeConsole = $true
    $writeFile = $true
    $minimumLevel = 'Information'
    $timestampFormat = 'yyyy-MM-dd HH:mm:ss'
    $includeCaller = $false

    if ($logging.PSObject.Properties.Name -contains 'Enabled') {
        $enabled = [bool]$logging.Enabled
    }

    if ($logging.PSObject.Properties.Name -contains 'WriteConsole') {
        $writeConsole = [bool]$logging.WriteConsole
    }

    if ($logging.PSObject.Properties.Name -contains 'WriteFile') {
        $writeFile = [bool]$logging.WriteFile
    }

    if ($logging.PSObject.Properties.Name -contains 'MinimumLevel') {
        $minimumLevel = [string]$logging.MinimumLevel
    }

    if ($logging.PSObject.Properties.Name -contains 'TimestampFormat') {
        $configuredTimestampFormat =
            [string]$logging.TimestampFormat

        if (
            -not [string]::IsNullOrWhiteSpace(
                $configuredTimestampFormat
            )
        ) {
            $timestampFormat = $configuredTimestampFormat
        }
    }

    if ($logging.PSObject.Properties.Name -contains 'IncludeCaller') {
        $includeCaller = [bool]$logging.IncludeCaller
    }

    $levelRanks = @{
        Debug       = 0
        Information = 1
        Warning     = 2
        Error       = 3
    }

    if (-not $levelRanks.ContainsKey($minimumLevel)) {
        throw (
            "Unsupported Logging.MinimumLevel value '$minimumLevel'. " +
            'Supported values are Debug, Information, Warning, and Error.'
        )
    }

    $filtered =
        $levelRanks[$Level] -lt
        $levelRanks[$minimumLevel]

    $caller = $null

    if ($includeCaller) {
        if (
            -not [string]::IsNullOrWhiteSpace(
                [string]$MyInvocation.ScriptName
            )
        ) {
            $caller =
                Split-Path `
                    -Path $MyInvocation.ScriptName `
                    -Leaf
        }
        else {
            $caller = '<Interactive>'
        }
    }

    $result = [pscustomobject]@{
        PSTypeName       = 'O365Toolkit.LogResult'
        Timestamp        = $Timestamp
        Level            = $Level
        Component        = $Component
        Message          = $Message
        Caller           = $caller
        Enabled          = $enabled
        Filtered         = $filtered
        WrittenToConsole = $false
        WrittenToFile    = $false
        LogPath          = $null
    }

    if (-not $enabled -or $filtered) {
        if ($PassThru) {
            return $result
        }

        return
    }

    try {
        $formattedTimestamp =
            $Timestamp.ToString($timestampFormat)
    }
    catch {
        throw (
            "Logging.TimestampFormat '$timestampFormat' is invalid: " +
            $_.Exception.Message
        )
    }

    $entryParts = @(
        "[$formattedTimestamp]"
        "[$Level]"
        "[$Component]"
    )

    if (
        $includeCaller -and
        -not [string]::IsNullOrWhiteSpace([string]$caller)
    ) {
        $entryParts += "[$caller]"
    }

    $entryParts += $Message

    $entry = $entryParts -join ' '

    if ($writeConsole) {
        Write-Host $entry
        $result.WrittenToConsole = $true
    }

    if ($writeFile) {
        $logPath =
            Resolve-ToolkitLogPath `
                -Config $Config `
                -Timestamp $Timestamp

        $logDirectory =
            Split-Path `
                -Path $logPath `
                -Parent

        if (
            -not (
                Test-Path `
                    -LiteralPath $logDirectory `
                    -PathType Container
            )
        ) {
            New-Item `
                -Path $logDirectory `
                -ItemType Directory `
                -Force `
                -ErrorAction Stop |
                Out-Null
        }

        Add-Content `
            -LiteralPath $logPath `
            -Value $entry `
            -Encoding utf8 `
            -ErrorAction Stop

        $result.WrittenToFile = $true
        $result.LogPath = $logPath
    }

    if ($PassThru) {
        return $result
    }
}
