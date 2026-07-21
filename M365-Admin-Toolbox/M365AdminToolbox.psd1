@{
    RootModule = 'M365AdminToolbox.psm1'
    ModuleVersion = '6.2.0'
    GUID = '7a2f0f4b-df42-4f35-9f7c-4b6de9db4a21'
    Author = 'Perplexity'
    CompanyName = 'Perplexity'
    Copyright = '(c) Perplexity'
    Description = 'Multi-tenant Microsoft 365 administration toolbox for Graph, Exchange Online, Intune, Entra, Azure, SharePoint, Teams, hybrid AD, reporting, and production hardening.'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Desktop','Core')
    FunctionsToExport = @(
        'Get-ToolboxRoot','Get-ConfigPath','Get-ToolboxConfig','Get-TenantConfig','Ensure-Directory','Write-ToolboxLog','Ensure-ModuleInstalled','Resolve-LicenseSkuIds',
        'Start-ToolboxTranscript','Stop-ToolboxTranscript','Invoke-ToolboxSafely','Invoke-WithRetry','Ensure-SecretModules','Initialize-ToolboxSecretStore','Set-ToolboxSecret','Get-ToolboxSecret','Sign-ToolboxScripts'
        ,'Invoke-M365Connect','Invoke-M365MailboxAudit','Invoke-M365UserOnboarding','Invoke-M365UserOffboarding','Invoke-M365BulkOnboarding','Invoke-M365LicenseInventoryReport','Invoke-M365SecurityAuditExport'
    )
    CmdletsToExport = @()
    VariablesToExport = '*'
    AliasesToExport = @()
    FileList = @(
        'M365AdminToolbox.psd1','M365AdminToolbox.psm1','README.md',
        'core\Common.ps1','core\Connect-M365.ps1','core\Logging.ps1','core\ErrorHandling.ps1','core\Retry.ps1','core\Secrets.ps1','core\CodeSigning.ps1'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('Microsoft365','Graph','ExchangeOnline','Intune','Entra','Azure','SharePoint','Teams','Hybrid','PowerShell')
            ProjectUri = 'https://example.invalid/M365AdminToolbox'
            ReleaseNotes = 'v6.2.0 adds exported advanced-function wrappers, comment-based help, and starter Pester tests.'
        }
    }
}
