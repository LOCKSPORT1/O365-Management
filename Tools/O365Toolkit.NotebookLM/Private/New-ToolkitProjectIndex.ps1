function New-ToolkitProjectIndex {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $false)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )

    # Safe fallback resolution for paths
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = $OutputDirectory
    }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = $PSScriptRoot
    }

    # If $OutputPath is passed as a directory or does not end with .md, safely append the target filename
    if ((Test-Path -LiteralPath $OutputPath -PathType Container) -or ($OutputPath -notmatch '\.md$')) {
        $OutputPath = Join-Path -Path $OutputPath -ChildPath 'Project_Index.md'
    }

    $outputDirectory = Split-Path `
        -Path $OutputPath `
        -Parent

    if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
        throw 'OutputPath must include a parent directory.'
    }

    if (-not (Test-Path -LiteralPath $outputDirectory)) {
        New-Item `
            -Path $outputDirectory `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop |
            Out-Null
    }

    $generatedAt = Get-Date `
        -Format 'yyyy-MM-dd HH:mm:ss zzz'

    $files = @(
        $Inventory.IncludedFiles
    )

    $powerShellFiles = @(
        $files |
        Where-Object {
            $_.Extension -in '.ps1', '.psm1'
        }
    )

    $functionEntries = foreach ($file in $powerShellFiles) {
        $tokens = $null
        $parseErrors = $null

        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )

        if ($parseErrors.Count -gt 0) {
            continue
        }

        $functionAsts = $ast.FindAll(
        {
            param($node)

            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        },
        $true)

        foreach ($functionAst in $functionAsts) {
            $visibility = if (
                $file.RelativePath -match '(?i)(^|[\\/])Public([\\/]|$)'
            ) {
                'Public'
            }
            elseif (
                $file.RelativePath -match '(?i)(^|[\\/])Private([\\/]|$)'
            ) {
                'Private'
            }
            else {
                'Unclassified'
            }

            [pscustomobject]@{
                Name         = $functionAst.Name
                Visibility   = $visibility
                RelativePath = $file.RelativePath
                StartLine    = $functionAst.Extent.StartLineNumber
                EndLine      = $functionAst.Extent.EndLineNumber
            }
        }
    }

    $moduleFiles = @(
        $files |
        Where-Object {
            $_.Extension -eq '.psm1'
        }
    )

    $manifestFiles = @(
        $files |
        Where-Object {
            $_.Extension -eq '.psd1'
        }
    )

    $testFiles = @(
        $files |
        Where-Object {
            $_.RelativePath -match '(?i)[\\/]Tests?[\\/]' -or
            $_.Name -match '(?i)\.Tests\.ps1$'
        }
    )

    $documentationFiles = @(
        $files |
        Where-Object {
            $_.Extension -in '.md', '.txt'
        }
    )

    $configurationFiles = @(
        $files |
        Where-Object {
            $_.Extension -in '.json', '.yml', '.yaml', '.xml'
        }
    )

    $templateFiles = @(
        $files |
        Where-Object {
            $_.RelativePath -match '(?i)(^|[\\/])templates?([\\/]|$)'
        }
    )

    $runbookFiles = @(
        $files |
        Where-Object {
            $_.RelativePath -match '(?i)runbook|playbook' -or
            $_.Name -match '(?i)runbook|playbook'
        }
    )

    $summaryLines = foreach (
        $summary in $Inventory.CategorySummary
    ) {
        "- $($summary.Category): $($summary.Count) files"
    }

    $moduleLines = foreach (
        $file in ($moduleFiles | Sort-Object RelativePath)
    ) {
        "- ``$($file.RelativePath)``"
    }

    $manifestLines = foreach (
        $file in ($manifestFiles | Sort-Object RelativePath)
    ) {
        "- ``$($file.RelativePath)``"
    }

    $publicFunctionLines = foreach (
        $function in (
            $functionEntries |
            Where-Object Visibility -eq 'Public' |
            Sort-Object Name, RelativePath
        )
    ) {
        "- ``$($function.Name)`` — ``$($function.RelativePath)``"
    }

    $privateFunctionLines = foreach (
        $function in (
            $functionEntries |
            Where-Object Visibility -eq 'Private' |
            Sort-Object Name, RelativePath
        )
    ) {
        "- ``$($function.Name)`` — ``$($function.RelativePath)``"
    }

    $unclassifiedFunctionLines = foreach (
        $function in (
            $functionEntries |
            Where-Object Visibility -eq 'Unclassified' |
            Sort-Object Name, RelativePath
        )
    ) {
        "- ``$($function.Name)`` — ``$($function.RelativePath)``"
    }

    $testLines = foreach (
        $file in ($testFiles | Sort-Object RelativePath)
    ) {
        "- ``$($file.RelativePath)``"
    }

    $documentationLines = foreach (
        $file in (
            $documentationFiles |
            Sort-Object RelativePath
        )
    ) {
        "- ``$($file.RelativePath)``"
    }

    $configurationLines = foreach (
        $file in (
            $configurationFiles |
            Sort-Object RelativePath
        )
    ) {
        "- ``$($file.RelativePath)``"
    }

    $templateLines = foreach (
        $file in ($templateFiles | Sort-Object RelativePath)
    ) {
        "- ``$($file.RelativePath)``"
    }

    $runbookLines = foreach (
        $file in ($runbookFiles | Sort-Object RelativePath)
    ) {
        "- ``$($file.RelativePath)``"
    }

    function ConvertTo-SectionText {
        param(
            [Parameter()]
            [AllowNull()]
            [object[]]$Lines,

            [Parameter(Mandatory)]
            [string]$EmptyMessage
        )

        $normalizedLines = @($Lines)

        if ($normalizedLines.Count -eq 0) {
            return $EmptyMessage
        }

        return $normalizedLines -join [environment]::NewLine
    }

    $content = @"
# O365 Management Toolkit Project Index

Generated: $generatedAt

## Repository Summary

- Repository path: ``$($Inventory.RepositoryPath)``
- Total safe files: $($Inventory.FileCount)

$(ConvertTo-SectionText `
    -Lines $summaryLines `
    -EmptyMessage 'No category summary was available.')

## PowerShell Modules

$(ConvertTo-SectionText `
    -Lines $moduleLines `
    -EmptyMessage 'No PowerShell module files were found.')

## PowerShell Manifests

$(ConvertTo-SectionText `
    -Lines $manifestLines `
    -EmptyMessage 'No PowerShell manifests were found.')

## Public Functions

$(ConvertTo-SectionText `
    -Lines $publicFunctionLines `
    -EmptyMessage 'No public functions were detected.')

## Private Helpers

$(ConvertTo-SectionText `
    -Lines $privateFunctionLines `
    -EmptyMessage 'No private helper functions were detected.')

## Unclassified Functions

$(ConvertTo-SectionText `
    -Lines $unclassifiedFunctionLines `
    -EmptyMessage 'No unclassified functions were detected.')

## Tests

$(ConvertTo-SectionText `
    -Lines $testLines `
    -EmptyMessage 'No test files were detected.')

## Runbooks and Playbooks

$(ConvertTo-SectionText `
    -Lines $runbookLines `
    -EmptyMessage 'No runbook or playbook files were detected by name or path.')

## Documentation

$(ConvertTo-SectionText `
    -Lines $documentationLines `
    -EmptyMessage 'No documentation files were detected.')

## Safe Configuration Examples

$(ConvertTo-SectionText `
    -Lines $configurationLines `
    -EmptyMessage 'No safe configuration example files were detected.')

## Templates

$(ConvertTo-SectionText `
    -Lines $templateLines `
    -EmptyMessage 'No template files were detected.')
"@

    Set-Content `
        -LiteralPath $OutputPath `
        -Value $content.TrimEnd() `
        -Encoding utf8 `
        -ErrorAction Stop

    return [pscustomobject]@{
        Success              = $true
        OutputPath           = $OutputPath
        TotalFiles           = $Inventory.FileCount
        FunctionCount        = @($functionEntries).Count
        PublicFunctionCount  = @(
            $functionEntries |
            Where-Object Visibility -eq 'Public'
        ).Count
        PrivateFunctionCount = @(
            $functionEntries |
            Where-Object Visibility -eq 'Private'
        ).Count
        TestFileCount        = $testFiles.Count
        DocumentationCount   = $documentationFiles.Count
        RunbookCount         = $runbookFiles.Count
        GeneratedAt          = $generatedAt
    }
}
