function Get-ToolkitNotebookMarker {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MarkerPath
    )

    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists                 = $false
            MarkerPath             = $MarkerPath
            ExportVersion          = $null
            BaselineCommit         = $null
            BaselineTag            = $null
            Branch                 = $null
            PreviousBaselineCommit = $null
            NextFeature            = $null
            RawContent             = $null
        }
    }

    $content = Get-Content `
        -LiteralPath $MarkerPath `
        -Raw `
        -ErrorAction Stop

    function Get-MarkerField {
        param(
            [Parameter(Mandatory)]
            [string]$Name
        )

        $escapedName = [regex]::Escape($Name)

        $match = [regex]::Match(
            $content,
            "(?im)^\s*${escapedName}\s*:\s*(.*?)\s*$"
        )

        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }

        return $null
    }

    return [pscustomobject]@{
        Exists                 = $true
        MarkerPath             = $MarkerPath
        ExportVersion          = Get-MarkerField -Name 'Export Version'
        BaselineCommit         = Get-MarkerField -Name 'Baseline Commit'
        BaselineTag            = Get-MarkerField -Name 'Baseline Tag'
        Branch                 = Get-MarkerField -Name 'Branch'
        PreviousBaselineCommit = Get-MarkerField -Name 'Previous Baseline Commit'
        NextFeature            = Get-MarkerField -Name 'Next Feature'
        RawContent             = $content
    }
}