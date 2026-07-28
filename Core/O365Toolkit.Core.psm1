Set-StrictMode -Version Latest

$PrivateFunctions =
    Get-ChildItem `
        -Path (Join-Path $PSScriptRoot 'Private') `
        -Filter '*.ps1' `
        -File `
        -ErrorAction SilentlyContinue

$PublicFunctions =
    Get-ChildItem `
        -Path (Join-Path $PSScriptRoot 'Public') `
        -Filter '*.ps1' `
        -File `
        -ErrorAction SilentlyContinue

foreach ($FunctionFile in @(
    $PrivateFunctions
    $PublicFunctions
)) {
    try {
        . $FunctionFile.FullName
    }
    catch {
        throw (
            "Failed to load function file '$($FunctionFile.FullName)': " +
            $_.Exception.Message
        )
    }
}

if ($PublicFunctions) {
    Export-ModuleMember `
        -Function $PublicFunctions.BaseName
}
