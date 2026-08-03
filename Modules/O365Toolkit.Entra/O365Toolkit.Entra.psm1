# O365Toolkit.Entra Module Root

$privateScripts = Get-ChildItem -Path "$PSScriptRoot\Private" -Filter '*.ps1' -ErrorAction SilentlyContinue
foreach ($script in $privateScripts) {
    try {
        . $script.FullName
    }
    catch {
        Write-Error "Failed to load private function file '$($script.Name)': $_"
    }
}

$publicScripts = Get-ChildItem -Path "$PSScriptRoot\Public" -Filter '*.ps1' -ErrorAction SilentlyContinue
foreach ($script in $publicScripts) {
    try {
        . $script.FullName
    }
    catch {
        Write-Error "Failed to load public function file '$($script.Name)': $_"
    }
}

$publicFunctions = @(
    $publicScripts | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
)

Export-ModuleMember -Function $publicFunctions
