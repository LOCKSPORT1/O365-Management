function Get-ToolkitNotebookGitSnapshot {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PreviousBaselineCommit
    )

    $resolvedRepositoryPath = (
        Resolve-Path `
            -LiteralPath $RepositoryPath `
            -ErrorAction Stop
    ).Path

    $branchOutput = @(
        Invoke-ToolkitGitCommand `
            -RepositoryPath $resolvedRepositoryPath `
            -ArgumentList @(
                'branch'
                '--show-current'
            )
    )

    $branch = $branchOutput |
        Select-Object -First 1

    $currentCommitOutput = @(
        Invoke-ToolkitGitCommand `
            -RepositoryPath $resolvedRepositoryPath `
            -ArgumentList @(
                'rev-parse'
                'HEAD'
            )
    )

    $currentCommit = $currentCommitOutput |
        Select-Object -First 1

    $latestTagOutput = @(
        Invoke-ToolkitGitCommand `
            -RepositoryPath $resolvedRepositoryPath `
            -ArgumentList @(
                'describe'
                '--tags'
                '--abbrev=0'
            ) `
            -AllowFailure
    )

    $latestTag = if ($latestTagOutput.Count -gt 0) {
        $latestTagOutput |
            Select-Object -First 1
    }
    else {
        'None'
    }

    $workingTreeStatus = @(
        Invoke-ToolkitGitCommand `
            -RepositoryPath $resolvedRepositoryPath `
            -ArgumentList @(
                'status'
                '--short'
            )
    )

    $isClean = $workingTreeStatus.Count -eq 0

    $hasPreviousBaseline = -not (
        [string]::IsNullOrWhiteSpace(
            $PreviousBaselineCommit
        ) -or
        $PreviousBaselineCommit -eq 'None'
    )

    $trimmedCurrentCommit = (
        [string]$currentCommit
    ).Trim()

    $incrementalRange = if ($hasPreviousBaseline) {
        "$PreviousBaselineCommit..$trimmedCurrentCommit"
    }
    else {
        $trimmedCurrentCommit
    }

    if ($hasPreviousBaseline) {
        $commitLog = @(
            Invoke-ToolkitGitCommand `
                -RepositoryPath $resolvedRepositoryPath `
                -ArgumentList @(
                    'log'
                    $incrementalRange
                    '--date=short'
                    '--pretty=format:%h | %ad | %s'
                )
        )

        $diffStat = @(
            Invoke-ToolkitGitCommand `
                -RepositoryPath $resolvedRepositoryPath `
                -ArgumentList @(
                    'diff'
                    '--stat'
                    $incrementalRange
                )
        )

        $changedFiles = @(
            Invoke-ToolkitGitCommand `
                -RepositoryPath $resolvedRepositoryPath `
                -ArgumentList @(
                    'diff'
                    '--name-status'
                    $incrementalRange
                )
        )
    }
    else {
        $commitLog = @(
            Invoke-ToolkitGitCommand `
                -RepositoryPath $resolvedRepositoryPath `
                -ArgumentList @(
                    'log'
                    '-20'
                    '--date=short'
                    '--pretty=format:%h | %ad | %s'
                )
        )

        $diffStat = @(
            'No previous baseline was provided.'
        )

        $changedFiles = @()
    }

    return [pscustomobject]@{
        RepositoryPath         = $resolvedRepositoryPath
        Branch                 = ([string]$branch).Trim()
        CurrentCommit          = $trimmedCurrentCommit
        LatestTag              = ([string]$latestTag).Trim()
        PreviousBaselineCommit = $PreviousBaselineCommit
        IncrementalRange       = $incrementalRange
        IsClean                = $isClean
        WorkingTreeStatus      = $workingTreeStatus
        CommitLog              = $commitLog
        DiffStat               = $diffStat
        ChangedFiles           = $changedFiles
    }
}