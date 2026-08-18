function Get-ToolkitNotebookRepositoryInventory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath
    )

    $resolvedRepositoryPath = (
        Resolve-Path `
            -LiteralPath $RepositoryPath `
            -ErrorAction Stop
    ).Path

    $includedExtensions = @(
        '.ps1'
        '.psm1'
        '.psd1'
        '.md'
        '.txt'
        '.json'
        '.yml'
        '.yaml'
        '.xml'
        '.csv'
    )

    $excludedDirectoryNames = @(
        '.git'
        '.github'
        'bin'
        'obj'
        'node_modules'
        'Logs'
        'Log'
        'Reports'
        'Report'
        'Exports'
        'Export'
        'Output'
        'Results'
        'PrivateExports'
        'Private-O365Toolkit-NotebookLM'
    )

    $excludedFilePatterns = @(
        '*.key'
        '*.pem'
        '*.pfx'
        '*.p12'
        '*.cer'
        '*.crt'
        '*.token'
        '*.secret'
        '*.secrets.*'
        '*.env'
        '.env*'
        '*credential*'
        '*password*'
        '*clientsecret*'
        '*accesstoken*'
        '*refreshtoken*'
        'tenants.json'
        'primary-user-audit.json'
        '*.log'
    )

    $allFiles = Get-ChildItem `
        -LiteralPath $resolvedRepositoryPath `
        -Recurse `
        -File `
        -Force `
        -ErrorAction Stop

    $includedFiles = foreach ($file in $allFiles) {
        $relativePath = $file.FullName.Substring(
            $resolvedRepositoryPath.Length
        ).TrimStart('\', '/')

        $relativeSegments = $relativePath -split '[\\/]'

        $isExcludedDirectory = $false

        foreach ($segment in $relativeSegments) {
            if ($excludedDirectoryNames -contains $segment) {
                $isExcludedDirectory = $true
                break
            }
        }

        if ($isExcludedDirectory) {
            continue
        }

        $extension = $file.Extension.ToLowerInvariant()

        if ($includedExtensions -notcontains $extension) {
            continue
        }

        # Only include CSV files stored in template folders.
        if (
            $extension -eq '.csv' -and
            $relativePath -notmatch '(?i)(^|[\\/])templates?([\\/]|$)'
        ) {
            continue
        }

        # Only include explicitly marked safe JSON examples/templates.
        if (
            $extension -eq '.json' -and
            $file.Name -notmatch '(?i)(example|sample|template)'
        ) {
            continue
        }

        $isExcludedFile = $false

        foreach ($pattern in $excludedFilePatterns) {
            if ($file.Name -like $pattern) {
                $isExcludedFile = $true
                break
            }
        }

        if ($isExcludedFile) {
            continue
        }

        $category = switch ($extension) {
            '.ps1'  { 'PowerShell Script' }
            '.psm1' { 'PowerShell Module' }
            '.psd1' { 'PowerShell Manifest' }
            '.md'   { 'Markdown Documentation' }
            '.txt'  { 'Text Documentation' }
            '.json' { 'JSON Configuration' }
            '.yml'  { 'YAML Configuration' }
            '.yaml' { 'YAML Configuration' }
            '.xml'  { 'XML Data' }
            '.csv'  { 'CSV Data' }
            default { 'Other' }
        }

        [pscustomobject]@{
            Name          = $file.Name
            FullName      = $file.FullName
            RelativePath  = $relativePath
            Extension     = $extension
            Category      = $category
            Length        = $file.Length
            LastWriteTime = $file.LastWriteTime
        }
    }

    $sortedFiles = @(
        $includedFiles |
        Sort-Object Category, RelativePath
    )

    $categorySummary = @(
        $sortedFiles |
        Group-Object Category |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Category = $_.Name
                Count    = $_.Count
                Bytes    = (
                    $_.Group |
                    Measure-Object Length -Sum
                ).Sum
            }
        }
    )

    return [pscustomobject]@{
        RepositoryPath  = $resolvedRepositoryPath
        IncludedFiles   = $sortedFiles
        FileCount       = $sortedFiles.Count
        CategorySummary = $categorySummary
        GeneratedAt     = Get-Date
    }
}
