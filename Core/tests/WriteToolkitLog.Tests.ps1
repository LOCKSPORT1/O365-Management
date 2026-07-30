BeforeAll {
    $modulePath =
        Join-Path `
            $PSScriptRoot `
            '..\O365Toolkit.Core.psd1'

    Import-Module $modulePath -Force

    function New-TestToolkitConfig {
        param(
            [Parameter(Mandatory)]
            [AllowEmptyString()]
            [string]$LogDirectory,

            [bool]$Enabled = $true,

            [string]$MinimumLevel = 'Information',

            [bool]$WriteConsole = $false,

            [bool]$WriteFile = $true,

            [bool]$DailyLogFiles = $true,

            [string]$TimestampFormat =
                'yyyy-MM-dd HH:mm:ss',

            [bool]$IncludeCaller = $false
        )

        return [pscustomobject]@{
            Paths = [pscustomobject]@{
                LogDirectory = $LogDirectory
            }

            Logging = [pscustomobject]@{
                Enabled         = $Enabled
                MinimumLevel    = $MinimumLevel
                WriteConsole    = $WriteConsole
                WriteFile       = $WriteFile
                DailyLogFiles   = $DailyLogFiles
                TimestampFormat = $TimestampFormat
                IncludeCaller   = $IncludeCaller
            }
        }
    }
}

AfterAll {
    Remove-Module O365Toolkit.Core -Force -ErrorAction SilentlyContinue
}

Describe 'Write-ToolkitLog module export' {
    It 'exports Write-ToolkitLog' {
        Get-Command `
            -Module O365Toolkit.Core `
            -Name Write-ToolkitLog |
            Should -Not -BeNullOrEmpty
    }

    It 'does not export Resolve-ToolkitLogPath' {
        Get-Command `
            -Module O365Toolkit.Core `
            -Name Resolve-ToolkitLogPath `
            -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
}

Describe 'Write-ToolkitLog' {
    It 'creates the configured log directory and daily log file' {
        $logDirectory =
            Join-Path $TestDrive 'daily-logs'

        $config =
            New-TestToolkitConfig `
                -LogDirectory $logDirectory

        $timestamp =
            [datetime]'2026-07-30 08:15:00'

        $result =
            Write-ToolkitLog `
                -Config $config `
                -Level Information `
                -Component 'Testing' `
                -Message 'Daily file test.' `
                -Timestamp $timestamp `
                -PassThru

        $result.WrittenToFile |
            Should -BeTrue

        $result.LogPath |
            Should -Be (
                Join-Path `
                    $logDirectory `
                    'O365Toolkit-2026-07-30.log'
            )

        Test-Path -LiteralPath $result.LogPath |
            Should -BeTrue
    }

    It 'writes the expected formatted entry to the file' {
        $logDirectory =
            Join-Path $TestDrive 'formatted-entry'

        $config =
            New-TestToolkitConfig `
                -LogDirectory $logDirectory

        $result =
            Write-ToolkitLog `
                -Config $config `
                -Level Warning `
                -Component 'UnitTest' `
                -Message 'Something requires attention.' `
                -Timestamp (
                    [datetime]'2026-07-30 09:30:45'
                ) `
                -PassThru

        $content =
            Get-Content `
                -LiteralPath $result.LogPath `
                -Raw

        $content |
            Should -Match (
                '\[2026-07-30 09:30:45\] ' +
                '\[Warning\] ' +
                '\[UnitTest\] ' +
                'Something requires attention\.'
            )
    }

    It 'uses a single static file when daily files are disabled' {
        $logDirectory =
            Join-Path $TestDrive 'static-log'

        $config =
            New-TestToolkitConfig `
                -LogDirectory $logDirectory `
                -DailyLogFiles $false

        $result =
            Write-ToolkitLog `
                -Config $config `
                -Message 'Static file test.' `
                -PassThru

        Split-Path `
            -Path $result.LogPath `
            -Leaf |
            Should -Be 'O365Toolkit.log'
    }

    It 'filters entries below the configured minimum level' {
        $logDirectory =
            Join-Path $TestDrive 'filtered-log'

        $config =
            New-TestToolkitConfig `
                -LogDirectory $logDirectory `
                -MinimumLevel 'Warning'

        $result =
            Write-ToolkitLog `
                -Config $config `
                -Level Information `
                -Message 'This should be filtered.' `
                -PassThru

        $result.Filtered |
            Should -BeTrue

        $result.WrittenToFile |
            Should -BeFalse

        Test-Path -LiteralPath $logDirectory |
            Should -BeFalse
    }

    It 'does not write when logging is disabled' {
        $logDirectory =
            Join-Path $TestDrive 'disabled-log'

        $config =
            New-TestToolkitConfig `
                -LogDirectory $logDirectory `
                -Enabled $false

        $result =
            Write-ToolkitLog `
                -Config $config `
                -Level Error `
                -Message 'Disabled logging test.' `
                -PassThru

        $result.Enabled |
            Should -BeFalse

        $result.WrittenToConsole |
            Should -BeFalse

        $result.WrittenToFile |
            Should -BeFalse

        Test-Path -LiteralPath $logDirectory |
            Should -BeFalse
    }

    It 'returns no pipeline output without PassThru' {
        $logDirectory =
            Join-Path $TestDrive 'no-output'

        $config =
            New-TestToolkitConfig `
                -LogDirectory $logDirectory

        $output =
            Write-ToolkitLog `
                -Config $config `
                -Message 'No pipeline output.'

        $output |
            Should -BeNullOrEmpty
    }

    It 'throws for an unsupported configured minimum level' {
        $logDirectory =
            Join-Path $TestDrive 'invalid-level'

        $config =
            New-TestToolkitConfig `
                -LogDirectory $logDirectory `
                -MinimumLevel 'Verbose'

        {
            Write-ToolkitLog `
                -Config $config `
                -Message 'Invalid level test.'
        } |
            Should -Throw '*Unsupported Logging.MinimumLevel*'
    }

    It 'throws when the log directory is empty' {
        $config =
            New-TestToolkitConfig `
                -LogDirectory ''

        {
            Write-ToolkitLog `
                -Config $config `
                -Message 'Missing path test.'
        } |
            Should -Throw '*Paths.LogDirectory cannot be empty*'
    }
}

