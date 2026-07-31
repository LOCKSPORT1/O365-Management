Set-StrictMode -Version Latest

$coreManifestPath = Join-Path `
    -Path $PSScriptRoot `
    -ChildPath '..\..\Core\O365Toolkit.Core.psd1'

$coreManifestPath = [System.IO.Path]::GetFullPath(
    $coreManifestPath
)

if (-not (Test-Path -LiteralPath $coreManifestPath -PathType Leaf)) {
    throw "O365Toolkit.Core manifest was not found: $coreManifestPath"
}

$coreModule = Get-Module O365Toolkit.Core |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (
    $null -eq $coreModule -or
    $coreModule.Version -lt [version]'0.5.0'
) {
    Import-Module `
        -Name $coreManifestPath `
        -MinimumVersion '0.5.0' `
        -Force `
        -ErrorAction Stop
}

$privatePath = Join-Path $PSScriptRoot 'Private'
$publicPath = Join-Path $PSScriptRoot 'Public'

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