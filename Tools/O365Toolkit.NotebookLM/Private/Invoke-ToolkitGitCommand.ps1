function Invoke-ToolkitGitCommand {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ArgumentList,

        [Parameter()]
        [switch]$AllowFailure
    )

    $resolvedRepositoryPath = (
        Resolve-Path `
            -LiteralPath $RepositoryPath `
            -ErrorAction Stop
    ).Path

    $gitDirectory = Join-Path `
        -Path $resolvedRepositoryPath `
        -ChildPath '.git'

    if (-not (Test-Path -LiteralPath $gitDirectory)) {
        throw (
            "The specified path is not a Git repository: " +
            $resolvedRepositoryPath
        )
    }

    $output = @(
        & git `
            -C $resolvedRepositoryPath `
            @ArgumentList `
            2>&1
    )

    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $message = if ($output.Count -gt 0) {
            $output -join [environment]::NewLine
        }
        else {
            'Git returned no error output.'
        }

        throw (
            "Git command failed with exit code ${exitCode}: " +
            "git $($ArgumentList -join ' ')" +
            [environment]::NewLine +
            $message
        )
    }

    return @(
        $output |
        ForEach-Object {
            [string]$_
        }
    )
}