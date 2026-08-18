function New-ToolkitProjectIndex {
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
        $DestinationPath = Join-Path -Path $RepositoryPath -ChildPath 'PrivateExports\Project_Index.md'
    }

    $parentDir = [System.IO.Path]::GetDirectoryName($DestinationPath)
    if ($parentDir -and -not (Test-Path -Path $parentDir)) {
        $null = New-Item -ItemType Directory -Path $parentDir -Force
    }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('# O365-Management Project Index')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("**Generated:** $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('---')
    $null = $sb.AppendLine()

    $manifests = Get-ChildItem -Path $RepositoryPath -Filter '*.psd1' -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/]PrivateExports[\\/]' }

    foreach ($m in $manifests) {
        $modName = [System.IO.Path]::GetFileNameWithoutExtension($m.Name)
        $modDir = $m.DirectoryName
        $null = $sb.AppendLine("## Module: ``$modName``")
        $null = $sb.AppendLine("- **Manifest:** ``$($m.Name)``")

        $pubDir = Join-Path -Path $modDir -ChildPath 'Public'
        if (Test-Path -Path $pubDir) {
            $pubCmds = (Get-ChildItem -Path $pubDir -Filter '*.ps1' | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) })
            $null = $sb.AppendLine("- **Public Functions:** $($pubCmds -join ', ')")
        }

        $testDir = Join-Path -Path $modDir -ChildPath 'Tests'
        if (Test-Path -Path $testDir) {
            $tests = (Get-ChildItem -Path $testDir -Filter '*.Tests.ps1' | ForEach-Object { $_.Name })
            $null = $sb.AppendLine("- **Pester Test Suites:** $($tests -join ', ')")
        }
        $null = $sb.AppendLine()
    }

    Set-Content -Path $DestinationPath -Value $sb.ToString() -Encoding utf8 -Force
    return $DestinationPath
}
