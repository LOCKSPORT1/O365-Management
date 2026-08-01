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
    throw "No private PowerShell function files were found in: $privatePath"
}

if ($publicFiles.Count -eq 0) {
    throw "No public PowerShell function files were found in: $publicPath"
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

$detectedPublicFunctions = @(
    foreach ($file in $publicFiles) {
        $tokens = $null
        $parseErrors = $null

        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )

        if (@($parseErrors).Count -gt 0) {
            $messages = @(
                $parseErrors |
                ForEach-Object {
                    $_.Message
                }
            ) -join '; '

            throw (
                "Failed to parse public function file '{0}': {1}" -f
                $file.FullName,
                $messages
            )
        }

        $functionDefinitions = $ast.FindAll(
            {
                param($node)

                $node -is [
                    System.Management.Automation.Language.FunctionDefinitionAst
                ]
            },
            $false
        )

        foreach ($functionDefinition in $functionDefinitions) {
            $functionDefinition.Name
        }
    }
)

$publicFunctionNames = @(
    $detectedPublicFunctions |
        Sort-Object -Unique
)

if ($publicFunctionNames.Count -eq 0) {
    throw 'No public functions were detected for export.'
}

Export-ModuleMember `
    -Function $publicFunctionNames
