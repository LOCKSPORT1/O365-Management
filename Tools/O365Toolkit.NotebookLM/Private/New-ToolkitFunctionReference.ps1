function New-ToolkitFunctionReference {
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

    $powerShellFiles = @(
        $Inventory.IncludedFiles |
        Where-Object {
            $_.Extension -in '.ps1', '.psm1'
        }
    )

    $functionReferences = foreach ($file in $powerShellFiles) {
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
            $true
        )

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

            $parameterNames = @()

            if ($null -ne $functionAst.Body.ParamBlock) {
                $parameterNames = @(
                    $functionAst.Body.ParamBlock.Parameters |
                    ForEach-Object {
                        $_.Name.VariablePath.UserPath
                    }
                )
            }

            $outputTypes = @()

            if ($null -ne $functionAst.Body.ParamBlock) {
                $outputTypes = @(
                    $functionAst.Body.ParamBlock.Attributes |
                    Where-Object {
                        $_.TypeName.FullName -eq 'OutputType'
                    } |
                    ForEach-Object {
                        $_.PositionalArguments.Extent.Text
                    }
                )
            }

            $synopsis = 'No synopsis is currently available.'

            $helpComment = $functionAst.GetHelpContent()

            if (
                $null -ne $helpComment -and
                -not [string]::IsNullOrWhiteSpace($helpComment.Synopsis)
            ) {
                $synopsis = $helpComment.Synopsis.Trim()
            }

            [pscustomobject]@{
                Name         = $functionAst.Name
                Visibility   = $visibility
                RelativePath = $file.RelativePath
                StartLine    = $functionAst.Extent.StartLineNumber
                EndLine      = $functionAst.Extent.EndLineNumber
                Parameters   = $parameterNames
                OutputTypes  = $outputTypes
                Synopsis     = $synopsis
            }
        }
    }

    $generatedAt = Get-Date `
        -Format 'yyyy-MM-dd HH:mm:ss zzz'

    $referenceSections = foreach (
        $function in (
            $functionReferences |
            Sort-Object Visibility, Name, RelativePath
        )
    ) {
        $parameterText = if (
            @($function.Parameters).Count -gt 0
        ) {
            @(
                $function.Parameters |
                ForEach-Object {
                    "- ``-$_``"
                }
            ) -join [environment]::NewLine
        }
        else {
            'No declared parameters.'
        }

        $outputTypeText = if (
            @($function.OutputTypes).Count -gt 0
        ) {
            @(
                $function.OutputTypes |
                ForEach-Object {
                    "- ``$_``"
                }
            ) -join [environment]::NewLine
        }
        else {
            'No OutputType attribute was detected.'
        }

@"
## $($function.Name)

- Visibility: $($function.Visibility)
- Source: ``$($function.RelativePath)``
- Lines: $($function.StartLine)-$($function.EndLine)

### Synopsis

$($function.Synopsis)

### Parameters

$parameterText

### Declared Output Types

$outputTypeText
"@
    }

    $content = @"
# O365 Management Toolkit Function Reference

Generated: $generatedAt

Total functions documented: $(@($functionReferences).Count)

$(
    $referenceSections -join (
        [environment]::NewLine +
        [environment]::NewLine
    )
)
"@

    Set-Content `
        -LiteralPath $OutputPath `
        -Value $content.TrimEnd() `
        -Encoding utf8 `
        -ErrorAction Stop

    return [pscustomobject]@{
        Success              = $true
        OutputPath           = $OutputPath
        FunctionCount        = @($functionReferences).Count
        PublicFunctionCount  = @(
            $functionReferences |
            Where-Object Visibility -eq 'Public'
        ).Count
        PrivateFunctionCount = @(
            $functionReferences |
            Where-Object Visibility -eq 'Private'
        ).Count
        GeneratedAt          = $generatedAt
    }
}
