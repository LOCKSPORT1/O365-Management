Set-StrictMode -Version Latest

$privatePath = Join-Path `
    -Path $PSScriptRoot `
    -ChildPath 'Private'

$publicPath = Join-Path `
    -Path $PSScriptRoot `
    -ChildPath 'Public'

$privateFiles = Get-ChildItem `
    -LiteralPath $privatePath `
    -Filter '*.ps1' `
    -File `
    -ErrorAction SilentlyContinue |
    Sort-Object Name

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

$publicFiles = Get-ChildItem `
    -LiteralPath $publicPath `
    -Filter '*.ps1' `
    -File `
    -ErrorAction SilentlyContinue |
    Sort-Object Name

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