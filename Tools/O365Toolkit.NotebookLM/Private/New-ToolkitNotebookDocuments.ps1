function New-ToolkitNotebookDocuments {
    [CmdletBinding()]
    [OutputType([string[]])]
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
        $DestinationPath = Join-Path -Path $RepositoryPath -ChildPath 'PrivateExports'
    }

    if (-not (Test-Path -Path $DestinationPath)) {
        $null = New-Item -ItemType Directory -Path $DestinationPath -Force
    }

    $copiedFiles = [System.Collections.Generic.List[string]]::new()
    $targetDocNames = @(
        'Architecture.md'
        'Decisions.md'
        'Development_Timeline.md'
        'O365Toolkit_Master_Guide.md'
        'NotebookLM_Prompts.txt'
        'README.md'
    )

    foreach ($docName in $targetDocNames) {
        $sourceFile = Join-Path -Path $RepositoryPath -ChildPath $docName
        if (Test-Path -Path $sourceFile) {
            $destFile = Join-Path -Path $DestinationPath -ChildPath $docName
            Copy-Item -Path $sourceFile -Destination $destFile -Force
            $copiedFiles.Add($destFile)
        }
    }

    return $copiedFiles.ToArray()
}
