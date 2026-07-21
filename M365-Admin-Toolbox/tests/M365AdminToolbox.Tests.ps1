$modulePath = Join-Path $PSScriptRoot '..\M365AdminToolbox.psd1'
Remove-Module M365AdminToolbox -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

Describe 'M365AdminToolbox module import' {
    It 'imports the module manifest successfully' {
        (Get-Module M365AdminToolbox).Name | Should -Be 'M365AdminToolbox'
    }
}

Describe 'Exported functions' {
    It 'exports Invoke-M365Connect' {
        Get-Command Invoke-M365Connect -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }

    It 'exports Invoke-M365UserOnboarding' {
        Get-Command Invoke-M365UserOnboarding -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }

    It 'exports Invoke-M365SecurityAuditExport' {
        Get-Command Invoke-M365SecurityAuditExport -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }
}
