# Modules/O365Toolkit.Exchange/Tests/Get-ToolkitMessageTrace.Tests.ps1
# Module : O365Toolkit.Exchange
# Track  : NEUTRAL
# Purpose: Contract tests for Get-ToolkitMessageTrace.
#          NOTE: the function currently returns representative structure rather
#          than querying a live service, so these tests validate the PUBLIC
#          CONTRACT - parameter binding, defaults, validation, and output shape.
#          They deliberately do not assert on the placeholder values, so a real
#          implementation can be dropped in without rewriting the suite.
# CHANGE : 2026-08-18 - v2. Import unconditionally rather than guarding on
#          Get-Module (the conditional form left the module unloaded in a clean
#          Pester scope, producing 14 CommandNotFoundException failures).
#          BeforeAll now throws immediately if the command is unavailable, and
#          the command-surface tests assert $cmd is non-null before using it so
#          they cannot pass against $null.

BeforeAll {
    $repoRoot     = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $corePsd1     = Join-Path -Path $repoRoot -ChildPath 'Core\O365Toolkit.Core.psd1'
    $exchangePsd1 = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'O365Toolkit.Exchange.psd1'

    if (-not (Test-Path -LiteralPath $corePsd1))     { throw "Core manifest not found at: $corePsd1" }
    if (-not (Test-Path -LiteralPath $exchangePsd1)) { throw "Exchange manifest not found at: $exchangePsd1" }

    # Unconditional. A conditional Get-Module guard silently skips the import
    # when the module was loaded by a different test run and then unloaded.
    Import-Module $corePsd1     -Force -ErrorAction Stop
    Import-Module $exchangePsd1 -Force -ErrorAction Stop

    # Fail loudly here rather than letting every It fail with CommandNotFound.
    if (-not (Get-Command -Name 'Get-ToolkitMessageTrace' -ErrorAction SilentlyContinue)) {
        throw "Get-ToolkitMessageTrace is not available after importing '$exchangePsd1'. Check FunctionsToExport in the manifest and that the .psm1 dot-sources Public\*.ps1."
    }
}

Describe 'Get-ToolkitMessageTrace' {

    Context 'Command surface' {

        It 'is exported by the Exchange module' {
            $cmd = Get-Command -Name 'Get-ToolkitMessageTrace' -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.ModuleName | Should -Be 'O365Toolkit.Exchange'
        }

        It 'exposes the documented parameters' {
            $cmd = Get-Command -Name 'Get-ToolkitMessageTrace' -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty

            foreach ($name in @('SenderAddress','RecipientAddress','StartDate','EndDate','Status','Config')) {
                $cmd.Parameters.Keys | Should -Contain $name
            }
        }

        It 'declares no mandatory parameters so it cannot prompt (R2.1)' {
            $cmd = Get-Command -Name 'Get-ToolkitMessageTrace' -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty

            $mandatory = @(
                $cmd.Parameters.Values |
                    Where-Object {
                        @($_.Attributes |
                            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }
                        ).Count -gt 0
                    }
            )
            $mandatory.Count | Should -Be 0
        }

        It 'does not declare a -First parameter (R2.6)' {
            $cmd = Get-Command -Name 'Get-ToolkitMessageTrace' -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Parameters.Keys | Should -Not -Contain 'First'
        }
    }

    Context 'Parameter validation' {

        It 'accepts every documented status value' {
            foreach ($status in @('Delivered','Failed','Pending','Expanded','Quarantined','Filtered')) {
                { Get-ToolkitMessageTrace -Status $status } | Should -Not -Throw
            }
        }

        It 'rejects a status outside the validated set' {
            { Get-ToolkitMessageTrace -Status 'Bounced' } | Should -Throw
        }

        It 'rejects a non-date value for StartDate' {
            { Get-ToolkitMessageTrace -StartDate 'not-a-date' } | Should -Throw
        }
    }

    Context 'Defaults' {

        It 'runs with no arguments at all' {
            { Get-ToolkitMessageTrace } | Should -Not -Throw
        }

        It 'runs when Config is omitted, null, or supplied (R2.2)' {
            { Get-ToolkitMessageTrace } | Should -Not -Throw
            { Get-ToolkitMessageTrace -Config $null } | Should -Not -Throw
            { Get-ToolkitMessageTrace -Config @{ Environment = 'Global' } } | Should -Not -Throw
        }

        It 'defines defaults for both ends of the date window' {
            $cmd = Get-Command -Name 'Get-ToolkitMessageTrace' -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty

            # Both are optional and typed as datetime, so an unbound call binds
            # the declared defaults rather than prompting or erroring.
            $cmd.Parameters['StartDate'].ParameterType | Should -Be ([datetime])
            $cmd.Parameters['EndDate'].ParameterType   | Should -Be ([datetime])

            $traces = @(Get-ToolkitMessageTrace)
            $traces.Count | Should -BeGreaterThan 0
        }
    }

    Context 'Output contract' {

        It 'returns at least one trace object' {
            $traces = @(Get-ToolkitMessageTrace)
            $traces.Count | Should -BeGreaterThan 0
        }

        It 'returns objects carrying the message-trace property set' {
            $trace = @(Get-ToolkitMessageTrace)[0]
            $trace | Should -Not -BeNullOrEmpty

            foreach ($property in @('Received','SenderAddress','RecipientAddress','Subject','Status','MessageId','Size')) {
                $trace.PSObject.Properties.Name | Should -Contain $property
            }
        }

        It 'types Received as a datetime and Size as a number' {
            $trace = @(Get-ToolkitMessageTrace)[0]
            $trace | Should -Not -BeNullOrEmpty
            $trace.Received | Should -BeOfType [datetime]
            $trace.Size     | Should -BeOfType [int]
        }
    }

    Context 'Filter propagation' {

        It 'reflects the supplied SenderAddress in the results' {
            $traces = @(Get-ToolkitMessageTrace -SenderAddress 'auditor@domain.com')
            $traces.Count | Should -BeGreaterThan 0
            $traces[0].SenderAddress | Should -Be 'auditor@domain.com'
        }

        It 'reflects the supplied RecipientAddress in the results' {
            $traces = @(Get-ToolkitMessageTrace -RecipientAddress 'recipient@domain.com')
            $traces.Count | Should -BeGreaterThan 0
            $traces[0].RecipientAddress | Should -Be 'recipient@domain.com'
        }

        It 'returns only records matching the requested Status' {
            $traces = @(Get-ToolkitMessageTrace -Status 'Failed')
            $traces.Count | Should -BeGreaterThan 0
            foreach ($t in $traces) {
                $t.Status | Should -Be 'Failed'
            }
        }

        It 'accepts sender and recipient together with a date window' {
            $start = (Get-Date).AddDays(-7)
            $end   = (Get-Date)

            $traces = @(Get-ToolkitMessageTrace `
                -SenderAddress 'auditor@domain.com' `
                -RecipientAddress 'recipient@domain.com' `
                -StartDate $start -EndDate $end)

            $traces.Count | Should -BeGreaterThan 0
            $traces[0].SenderAddress    | Should -Be 'auditor@domain.com'
            $traces[0].RecipientAddress | Should -Be 'recipient@domain.com'
        }
    }

    Context 'Pipeline behaviour' {

        It 'emits to the pipeline so Select-Object -First works (R2.6)' {
            $first = Get-ToolkitMessageTrace | Select-Object -First 1
            $first | Should -Not -BeNullOrEmpty
        }
    }
}
