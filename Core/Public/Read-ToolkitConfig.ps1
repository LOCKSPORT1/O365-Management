function Read-ToolkitConfig {
    <#
    .SYNOPSIS
        Loads and validates an O365 Management Toolkit JSON configuration file.

    .DESCRIPTION
        Reads a JSON configuration file and returns a normalized configuration
        object.

        The function validates required top-level sections and expands relative
        paths from the location of the configuration file.

    .PARAMETER Path
        Path to the JSON configuration file.

    .EXAMPLE
        $config =
            Read-ToolkitConfig `
                -Path '.\config\toolkit.example.json'
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    Set-StrictMode -Version Latest

    if (
        -not (
            Test-Path `
                -LiteralPath $Path `
                -PathType Leaf
        )
    ) {
        throw "Configuration file was not found: $Path"
    }

    $resolvedPath =
        (Resolve-Path -LiteralPath $Path).Path

    try {
        $rawContent =
            Get-Content `
                -LiteralPath $resolvedPath `
                -Raw `
                -ErrorAction Stop

        $config =
            $rawContent |
            ConvertFrom-Json `
                -Depth 20 `
                -ErrorAction Stop
    }
    catch {
        throw (
            "Failed to read configuration file '$resolvedPath': " +
            $_.Exception.Message
        )
    }

    $requiredSections =
        @(
            'Toolkit'
            'Tenant'
            'Paths'
            'Graph'
            'Logging'
        )

    foreach ($section in $requiredSections) {
        if (
            $config.PSObject.Properties.Name -notcontains
            $section
        ) {
            throw (
                "Configuration file is missing required section '$section'."
            )
        }
    }

    if (
        [string]::IsNullOrWhiteSpace(
            [string]$config.Toolkit.Name
        )
    ) {
        throw 'Toolkit.Name is required.'
    }

    if (
        [string]::IsNullOrWhiteSpace(
            [string]$config.Toolkit.Environment
        )
    ) {
        throw 'Toolkit.Environment is required.'
    }

    $configDirectory =
        Split-Path `
            -Path $resolvedPath `
            -Parent

    foreach ($propertyName in @(
        'LogDirectory'
        'ReportDirectory'
        'RollbackDirectory'
    )) {
        if (
            $config.Paths.PSObject.Properties.Name -contains
            $propertyName
        ) {
            $configuredPath =
                [string]$config.Paths.$propertyName

            if (
                -not [string]::IsNullOrWhiteSpace(
                    $configuredPath
                )
            ) {
                if (
                    [System.IO.Path]::IsPathRooted(
                        $configuredPath
                    )
                ) {
                    $expandedPath =
                        [System.IO.Path]::GetFullPath(
                            $configuredPath
                        )
                }
                else {
                    $expandedPath =
                        [System.IO.Path]::GetFullPath(
                            (
                                Join-Path `
                                    $configDirectory `
                                    $configuredPath
                            )
                        )
                }

                $config.Paths.$propertyName =
                    $expandedPath
            }
        }
    }

    return [pscustomobject]@{
        ConfigurationPath =
            $resolvedPath

        ConfigurationDirectory =
            $configDirectory

        Toolkit =
            $config.Toolkit

        Tenant =
            $config.Tenant

        Paths =
            $config.Paths

        Graph =
            $config.Graph

        Logging =
            $config.Logging

        RawConfiguration =
            $config
    }
}
