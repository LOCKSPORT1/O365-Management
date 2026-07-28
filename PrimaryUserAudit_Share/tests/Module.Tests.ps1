BeforeAll {
    $moduleManifest = Join-Path `
        $PSScriptRoot `
        '..\PrimaryUserAudit.psd1'

    Remove-Module PrimaryUserAudit `
        -Force `
        -ErrorAction SilentlyContinue

    Import-Module $moduleManifest `
        -Force `
        -ErrorAction Stop
}

Describe 'PrimaryUserAudit module' {
    It 'has a valid module manifest' {
        $moduleManifest = Join-Path `
            $PSScriptRoot `
            '..\PrimaryUserAudit.psd1'

        {
            Test-ModuleManifest `
                -Path $moduleManifest `
                -ErrorAction Stop
        } | Should -Not -Throw
    }

    It 'imports successfully' {
        Get-Module PrimaryUserAudit |
            Should -Not -BeNullOrEmpty
    }

    It 'exports Invoke-PrimaryUserAudit' {
        Get-Command `
            -Name Invoke-PrimaryUserAudit `
            -Module PrimaryUserAudit `
            -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'does not export private device collection functions' {
        $exportedCommands = @(
            Get-Command -Module PrimaryUserAudit
        )

        $exportedCommands.Name |
            Should -Not -Contain 'Get-ManagedWindowsDevice'
    }

    It 'does not export the Graph retry helper' {
        $exportedCommands = @(
            Get-Command -Module PrimaryUserAudit
        )

        $exportedCommands.Name |
            Should -Not -Contain 'Invoke-GraphRequestWithRetry'
    }
}