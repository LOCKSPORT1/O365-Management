Set-StrictMode -Version Latest

$privatePath = Join-Path `
    -Path $PSScriptRoot `
    -ChildPath 'Private'

$publicPath = Join-Path `
    -Path $PSScriptRoot `
    -ChildPath 'Public'

if (-not (Test-Path -LiteralPath $privatePath -PathType Container)) {
    throw "Private function directory was not found: $privatePath"
}

if (-not (Test-Path -LiteralPath $publicPath -PathType Container)) {
    throw "Public function directory was not found: $publicPath"
}

$privateFiles = @(
    Get-ChildItem `
        -LiteralPath $privatePath `
        -Filter '*.ps1' `
        -File `
        -ErrorAction Stop |
        Sort-Object Name
)

$publicFiles = @(
    Get-ChildItem `
        -LiteralPath $publicPath `
        -Filter '*.ps1' `
        -File `
        -ErrorAction Stop |
        Sort-Object Name
)

if ($privateFiles.Count -eq 0) {
    throw "No private function files were found in: $privatePath"
}

if ($publicFiles.Count -eq 0) {
    throw "No public function files were found in: $publicPath"
}

foreach ($file in $privateFiles) {
    try {
        . $file.FullName
    }
    catch {
        throw (
            "Failed to load private function file '{0}': {1}" -f
            $file.FullName,
            $_.Exception.Message
        )
    }
}

foreach ($file in $publicFiles) {
    try {
        . $file.FullName
    }
    catch {
        throw (
            "Failed to load public function file '{0}': {1}" -f
            $file.FullName,
            $_.Exception.Message
        )
    }
}

Export-ModuleMember `
    -Function 'New-ToolkitNotebookExport'
