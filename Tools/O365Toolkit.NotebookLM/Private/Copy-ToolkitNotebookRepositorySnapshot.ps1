function Copy-ToolkitNotebookRepositorySnapshot {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Inventory,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Alias('Path')]
        [string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        New-Item `
            -Path $DestinationPath `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop |
            Out-Null
    }

    $copiedFiles = foreach ($file in $Inventory.IncludedFiles) {
        $destination = Join-Path `
            -Path $DestinationPath `
            -ChildPath $file.RelativePath

        $destinationDirectory = Split-Path `
            -Path $destination `
            -Parent

        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            New-Item `
                -Path $destinationDirectory `
                -ItemType Directory `
                -Force `
                -ErrorAction Stop |
                Out-Null
        }

        Copy-Item `
            -LiteralPath $file.FullName `
            -Destination $destination `
            -Force `
            -ErrorAction Stop

        Get-Item `
            -LiteralPath $destination `
            -ErrorAction Stop
    }

    return [pscustomobject]@{
        Success         = $true
        DestinationPath = $DestinationPath
        FileCount       = @($copiedFiles).Count
        CopiedFiles     = @($copiedFiles)
        CompletedAt     = Get-Date
    }
}
