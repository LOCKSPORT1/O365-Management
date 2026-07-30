Set-StrictMode -Version Latest

$privatePath = Join-Path $PSScriptRoot 'Private'
$publicPath  = Join-Path $PSScriptRoot 'Public'

$privateFiles = Get-ChildItem `
    -Path $privatePath `
    -Filter '*.ps1' `
    -File `
    -ErrorAction SilentlyContinue |
    Sort-Object Name

foreach ($file in $privateFiles) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to load private function file '$($file.FullName)': $($_.Exception.Message)"
    }
}

$publicFiles = Get-ChildItem `
    -Path $publicPath `
    -Filter '*.ps1' `
    -File `
    -ErrorAction SilentlyContinue |
    Sort-Object Name

foreach ($file in $publicFiles) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to load public function file '$($file.FullName)': $($_.Exception.Message)"
    }
}
