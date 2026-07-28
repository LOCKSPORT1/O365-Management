# PrimaryUserAudit.psm1
# Loads private helper functions and public commands.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$privatePath = Join-Path $PSScriptRoot 'Private'
$publicPath  = Join-Path $PSScriptRoot 'Public'

$privateScripts = @(
    Get-ChildItem `
        -Path $privatePath `
        -Filter '*.ps1' `
        -File `
        -ErrorAction Stop |
    Sort-Object Name
)

$publicScripts = @(
    Get-ChildItem `
        -Path $publicPath `
        -Filter '*.ps1' `
        -File `
        -ErrorAction Stop |
    Sort-Object Name
)

foreach ($script in $privateScripts) {
    try {
        . $script.FullName
    }
    catch {
        throw "Failed to load private function file '$($script.Name)': $($_.Exception.Message)"
    }
}

foreach ($script in $publicScripts) {
    try {
        . $script.FullName
    }
    catch {
        throw "Failed to load public function file '$($script.Name)': $($_.Exception.Message)"
    }
}

$publicFunctions = @(
    $publicScripts |
    ForEach-Object {
        [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    }
)

Export-ModuleMember -Function $publicFunctions