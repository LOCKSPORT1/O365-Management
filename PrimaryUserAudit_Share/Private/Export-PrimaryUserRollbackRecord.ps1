function Export-PrimaryUserRollbackRecord {
    <#
    .SYNOPSIS
        Exports Intune primary-user rollback records to JSON.

    .DESCRIPTION
        Writes one or more rollback records to a timestamped JSON file.

        The resulting file can later be consumed by a rollback command to
        restore previous Intune primary-user assignments.

    .PARAMETER Record
        One or more rollback records.

    .PARAMETER OutputDirectory
        Directory where the rollback JSON file will be created.

    .PARAMETER OutputPath
        Optional complete path for the rollback JSON file. When supplied,
        OutputDirectory is ignored.

    .EXAMPLE
        Export-PrimaryUserRollbackRecord `
            -Record $rollbackRecords `
            -OutputDirectory '.\Rollback'
    #>

    [CmdletBinding()]
    param(
        [Parameter(
            Mandatory,
            ValueFromPipeline
        )]
        [ValidateNotNull()]
        [object[]]$Record,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OutputDirectory =
            (Join-Path $PWD 'Rollback'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath
    )

    begin {
        Set-StrictMode -Version Latest

        $records =
            [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $Record) {
            if ($null -ne $item) {
                $records.Add($item)
            }
        }
    }

    end {
        if ($records.Count -eq 0) {
            throw 'At least one rollback record is required.'
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $OutputPath
            )
        ) {
            if (
                -not (
                    Test-Path `
                        -LiteralPath $OutputDirectory `
                        -PathType Container
                )
            ) {
                $null =
                    New-Item `
                        -Path $OutputDirectory `
                        -ItemType Directory `
                        -Force
            }

            $timestamp =
                Get-Date -Format 'yyyyMMdd_HHmmss'

            $OutputPath =
                Join-Path `
                    $OutputDirectory `
                    "PrimaryUserRollback_$timestamp.json"
        }
        else {
            $parentDirectory =
                Split-Path `
                    -Path $OutputPath `
                    -Parent

            if (
                -not [string]::IsNullOrWhiteSpace(
                    $parentDirectory
                ) -and
                -not (
                    Test-Path `
                        -LiteralPath $parentDirectory `
                        -PathType Container
                )
            ) {
                $null =
                    New-Item `
                        -Path $parentDirectory `
                        -ItemType Directory `
                        -Force
            }
        }

        $normalizedRecords =
            foreach ($item in $records) {
                [pscustomobject]@{
                    SchemaVersion =
                        '1.0'

                    DeviceName =
                        [string]$item.DeviceName

                    ManagedDeviceId =
                        [string]$item.ManagedDeviceId

                    PreviousUserId =
                        [string]$item.PreviousUserId

                    PreviousUserPrincipal =
                        [string]$item.PreviousUserPrincipal

                    NewUserId =
                        [string]$item.NewUserId

                    NewUserPrincipal =
                        [string]$item.NewUserPrincipal

                    RecommendedAction =
                        [string]$item.RecommendedAction

                    RemediationStatus =
                        [string]$item.RemediationStatus

                    VerificationStatus =
                        [string]$item.VerificationStatus

                    Timestamp =
                        if (
                            $item.PSObject.Properties.Name -contains
                            'Timestamp' -and
                            $null -ne $item.Timestamp
                        ) {
                            (
                                [datetimeoffset]$item.Timestamp
                            ).ToString('o')
                        }
                        else {
                            [datetimeoffset]::Now.ToString('o')
                        }
                }
            }

        $json =
            ConvertTo-Json `
                -InputObject @($normalizedRecords) `
                -Depth 6

        Set-Content `
            -LiteralPath $OutputPath `
            -Value $json `
            -Encoding utf8

        $resolvedPath =
            (Resolve-Path -LiteralPath $OutputPath).Path

        return [pscustomobject]@{
            OutputPath =
                $resolvedPath

            RecordCount =
                $records.Count

            ExportStatus =
                'Completed'
        }
    }
}
