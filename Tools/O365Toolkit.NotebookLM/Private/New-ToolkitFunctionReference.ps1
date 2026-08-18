function New-ToolkitFunctionReference {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [Alias('Path')]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [string]$RepositoryPath,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Config = @{ Environment = 'Global' }
    )

    if (-not $Config) { $Config = @{ Environment = 'Global' } }
    if (-not $RepositoryPath) { $RepositoryPath = (Get-Location).Path }
    if (-not $DestinationPath) {
        $DestinationPath = Join-Path -Path $RepositoryPath -ChildPath 'PrivateExports\Function_Reference.md'
    }

    $parentDir = [System.IO.Path]::GetDirectoryName($DestinationPath)
    if ($parentDir -and -not (Test-Path -Path $parentDir)) {
        $null = New-Item -ItemType Directory -Path $parentDir -Force
    }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('# O365-Management Function Reference')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("**Generated:** $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('---')
    $null = $sb.AppendLine()

    $scripts = Get-ChildItem -Path $RepositoryPath -Filter '*.ps1' -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' -and $_.FullName -notmatch '[\\/]PrivateExports[\\/]' }

    foreach ($script in $scripts) {
        $relPath = $script.FullName.Substring($RepositoryPath.Length).TrimStart('\', '/')
        $content = Get-Content -Path $script.FullName -Raw

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
        $functions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

        foreach ($fn in $functions) {
            $null = $sb.AppendLine("## $($fn.Name)")
            $null = $sb.AppendLine("- **Source File:** ``$relPath``")

            $paramNames = @()
            if ($fn.Body.ParamBlock -and $fn.Body.ParamBlock.Parameters) {
                foreach ($p in $fn.Body.ParamBlock.Parameters) {
                    $paramNames += "-``$($p.Name.VariablePath.UserPath)``"
                }
            }

            if ($paramNames.Count -gt 0) {
                $null = $sb.AppendLine("- **Parameters:** $($paramNames -join ', ')")
            } else {
                $null = $sb.AppendLine('- **Parameters:** None')
            }
            $null = $sb.AppendLine()
        }
    }

    Set-Content -Path $DestinationPath -Value $sb.ToString() -Encoding utf8 -Force
    return $DestinationPath
}
