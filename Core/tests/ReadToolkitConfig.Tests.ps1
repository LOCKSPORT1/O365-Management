BeforeAll {
    Remove-Module O365Toolkit.Core -Force -ErrorAction SilentlyContinue

    Import-Module `
        "$PSScriptRoot\..\O365Toolkit.Core.psd1" `
        -Force
}

Describe 'O365Toolkit.Core module' {
    It 'has a valid module manifest' {
        Test-ModuleManifest `
            "$PSScriptRoot\..\O365Toolkit.Core.psd1" |
            Should -Not -BeNullOrEmpty
    }

    It 'exports Read-ToolkitConfig' {
        Get-Command `
            Read-ToolkitConfig `
            -Module O365Toolkit.Core |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'Read-ToolkitConfig' {
    BeforeEach {
        $ConfigPath = Join-Path $TestDrive 'toolkit.json'

        @'
{
  "Toolkit": {
    "Name": "Test Toolkit",
    "Environment": "Test",
    "Version": "0.1.0"
  },
  "Tenant": {
    "TenantId": "",
    "PrimaryDomain": "example.com",
    "OrganizationName": "Example"
  },
  "Paths": {
    "LogDirectory": "./logs",
    "ReportDirectory": "./reports",
    "RollbackDirectory": "./reports/rollback"
  },
  "Graph": {
    "CloudEnvironment": "Global",
    "ApiVersion": "v1.0",
    "RetryCount": 5,
    "RetryDelaySeconds": 3,
    "Scopes": []
  },
  "Logging": {
    "Enabled": true,
    "MinimumLevel": "Information",
    "WriteConsole": true,
    "WriteFile": true
  }
}
'@ | Set-Content `
            -Path $ConfigPath `
            -Encoding utf8
    }

    It 'loads a valid configuration file' {
        $result = Read-ToolkitConfig -Path $ConfigPath

        $result.Toolkit.Name | Should -Be 'Test Toolkit'
        $result.Toolkit.Environment | Should -Be 'Test'
        $result.Tenant.PrimaryDomain | Should -Be 'example.com'
    }

    It 'returns the resolved configuration path' {
        $result = Read-ToolkitConfig -Path $ConfigPath

        $result.ConfigurationPath |
            Should -Be ((Resolve-Path $ConfigPath).Path)
    }

    It 'expands relative toolkit paths' {
        $result = Read-ToolkitConfig -Path $ConfigPath

        [System.IO.Path]::IsPathRooted(
            $result.Paths.LogDirectory
        ) | Should -BeTrue

        [System.IO.Path]::IsPathRooted(
            $result.Paths.ReportDirectory
        ) | Should -BeTrue
    }

    It 'throws when the configuration file does not exist' {
        {
            Read-ToolkitConfig `
                -Path (Join-Path $TestDrive 'missing.json')
        } | Should -Throw
    }

    It 'throws when a required section is missing' {
        @'
{
  "Toolkit": {
    "Name": "Test Toolkit",
    "Environment": "Test"
  }
}
'@ | Set-Content `
            -Path $ConfigPath `
            -Encoding utf8

        {
            Read-ToolkitConfig -Path $ConfigPath
        } | Should -Throw
    }

    It 'throws when the JSON is invalid' {
        '{ invalid json' |
            Set-Content `
                -Path $ConfigPath `
                -Encoding utf8

        {
            Read-ToolkitConfig -Path $ConfigPath
        } | Should -Throw
    }
}

AfterAll {
    Remove-Module O365Toolkit.Core -Force -ErrorAction SilentlyContinue
}