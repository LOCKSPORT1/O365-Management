function New-ToolkitModuleBooks {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Inventory,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item `
            -Path $OutputPath `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop |
            Out-Null
    }

    $sourceFiles = @(
        $Inventory.IncludedFiles |
        Where-Object {
            $_.Extension -in @(
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
        } |
        Sort-Object RelativePath
    )

    function Get-ToolkitBookDefinition {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$RelativePath
        )

        $normalizedPath = $RelativePath -replace '\\', '/'

        if ($normalizedPath -match '^Core/') {
            return [pscustomobject]@{
                Key      = 'Core'
                FileName = '05_Core_Module_Source.md'
                Title    = 'O365 Toolkit Core Module'
            }
        }

        if ($normalizedPath -match '^Modules/([^/]+)/') {
            $moduleName = $matches[1]
            $safeName = $moduleName -replace '[^A-Za-z0-9]+', '_'

            return [pscustomobject]@{
                Key      = "Module:$moduleName"
                FileName = "06_${safeName}_Module_Source.md"
                Title    = "$moduleName Module"
            }
        }

        if (
            $normalizedPath -match
            '^Tools/O365Toolkit\.NotebookLM/'
        ) {
            return [pscustomobject]@{
                Key      = 'NotebookLM'
                FileName = '07_NotebookLM_Compiler_Source.md'
                Title    = 'NotebookLM Knowledge Compiler'
            }
        }

        if ($normalizedPath -match '^PrimaryUserAudit_Share/') {
            return [pscustomobject]@{
                Key      = 'PrimaryUserAudit'
                FileName = '08_Primary_User_Audit_Source.md'
                Title    = 'Primary User Audit'
            }
        }

        if ($normalizedPath -match '^M365-Admin-Toolbox/') {
            return [pscustomobject]@{
                Key      = 'AdminToolbox'
                FileName = '09_M365_Admin_Toolbox_Source.md'
                Title    = 'Microsoft 365 Administration Toolbox'
            }
        }

        if (
            $normalizedPath -match
            '(?i)(runbook|playbook|procedure)'
        ) {
            return [pscustomobject]@{
                Key      = 'Runbooks'
                FileName = '10_Runbooks_and_Playbooks.md'
                Title    = 'Runbooks and Playbooks'
            }
        }

        return [pscustomobject]@{
            Key      = 'Additional'
            FileName = '11_Additional_Project_Source.md'
            Title    = 'Additional Project Source'
        }
    }

    function Get-ToolkitFenceLanguage {
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)]
            [string]$Extension
        )

        switch ($Extension.ToLowerInvariant()) {
            '.ps1'  { return 'powershell' }
            '.psm1' { return 'powershell' }
            '.psd1' { return 'powershell' }
            '.md'   { return 'markdown' }
            '.json' { return 'json' }
            '.yml'  { return 'yaml' }
            '.yaml' { return 'yaml' }
            '.xml'  { return 'xml' }
            '.csv'  { return 'csv' }
            default { return 'text' }
        }
    }

    $bookGroups = @{}

    foreach ($file in $sourceFiles) {
        $definition = Get-ToolkitBookDefinition `
            -RelativePath $file.RelativePath

        if (-not $bookGroups.ContainsKey($definition.Key)) {
            $bookGroups[$definition.Key] = [pscustomobject]@{
                Definition = $definition
                Files = [System.Collections.Generic.List[object]]::new()
            }
        }

        $bookGroups[$definition.Key].Files.Add($file)
    }

    $createdBooks = @()
    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'

    foreach (
        $group in (
            $bookGroups.Values |
            Sort-Object {
                $_.Definition.FileName
            }
        )
    ) {
        $definition = $group.Definition

        $bookPath = Join-Path `
            -Path $OutputPath `
            -ChildPath $definition.FileName

        $builder = [System.Text.StringBuilder]::new()

        [void]$builder.AppendLine("# $($definition.Title)")
        [void]$builder.AppendLine()
        [void]$builder.AppendLine("Generated: $generatedAt")
        [void]$builder.AppendLine()
        [void]$builder.AppendLine(
            "Files compiled: $($group.Files.Count)"
        )
        [void]$builder.AppendLine()

        foreach (
            $file in (
                $group.Files |
                Sort-Object RelativePath
            )
        ) {
            $language = Get-ToolkitFenceLanguage `
                -Extension $file.Extension

            try {
                $content = Get-Content `
                    -LiteralPath $file.FullName `
                    -Raw `
                    -ErrorAction Stop
            }
            catch {
                $content = (
                    'Unable to read this file during compilation: ' +
                    $_.Exception.Message
                )
            }

            if ($null -eq $content) {
                $content = ''
            }

            [void]$builder.AppendLine(
                "## $($file.RelativePath)"
            )
            [void]$builder.AppendLine()
            [void]$builder.AppendLine(
                "- Category: $($file.Category)"
            )
            [void]$builder.AppendLine(
                "- Size: $($file.Length) bytes"
            )
            [void]$builder.AppendLine()
            [void]$builder.AppendLine("~~~$language")
            [void]$builder.AppendLine($content.TrimEnd())
            [void]$builder.AppendLine('~~~')
            [void]$builder.AppendLine()
        }

        Set-Content `
            -LiteralPath $bookPath `
            -Value $builder.ToString().TrimEnd() `
            -Encoding utf8 `
            -ErrorAction Stop

        $createdBooks += [pscustomobject]@{
            Key       = $definition.Key
            Title     = $definition.Title
            FileName  = $definition.FileName
            Path      = $bookPath
            FileCount = $group.Files.Count
            Length    = (
                Get-Item -LiteralPath $bookPath
            ).Length
        }
    }

    return [pscustomobject]@{
        Success      = $true
        OutputPath   = $OutputPath
        BookCount    = @($createdBooks).Count
        SourceCount  = @($sourceFiles).Count
        CreatedBooks = $createdBooks
        GeneratedAt  = $generatedAt
    }
}
