function Import-PrimaryUserRollbackRecord {
    <#
    .SYNOPSIS
        Imports and validates Intune primary-user rollback records.

    .DESCRIPTION
        Reads a rollback JSON file created by
        Export-PrimaryUserRollbackRecord.

        The function validates the rollback schema, required properties,
        managed-device IDs, and user IDs before returning normalized
        rollback records.

    .PARAMETER Path
        Path to the rollback JSON file.

    .EXAMPLE
        Import-PrimaryUserRollbackRecord `
            -Path '.\Rollback\PrimaryUserRollback_20260728_140000.json'
    #>

    [CmdletBinding()]
    param(
        [Parameter(
            Mandatory,
            Position = 0
        )]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $supportedSchemaVersion = '1.0'

    if (
        -not (
            Test-Path `
                -LiteralPath $Path `
                -PathType Leaf
        )
    ) {
        throw "Rollback file was not found: $Path"
    }

    try {
        $resolvedPath =
            (Resolve-Path -LiteralPath $Path).Path

        $rawContent =
            Get-Content `
                -LiteralPath $resolvedPath `
                -Raw `
                -ErrorAction Stop
    }
    catch {
        throw "Unable to read rollback file '$Path': $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($rawContent)) {
        throw "Rollback file is empty: $resolvedPath"
    }

    try {
        $importedContent =
            $rawContent |
                ConvertFrom-Json `
                    -ErrorAction Stop
    }
    catch {
        throw "Rollback file contains invalid JSON: $($_.Exception.Message)"
    }

    $records = @($importedContent)

    if ($records.Count -eq 0) {
        throw 'Rollback file does not contain any records.'
    }

    $requiredProperties = @(
        'SchemaVersion'
        'DeviceName'
        'ManagedDeviceId'
        'PreviousUserId'
        'PreviousUserPrincipal'
        'NewUserId'
        'NewUserPrincipal'
        'RecommendedAction'
        'RemediationStatus'
        'VerificationStatus'
        'Timestamp'
    )

    $normalizedRecords =
        [System.Collections.Generic.List[object]]::new()

    for (
        $recordIndex = 0
        $recordIndex -lt $records.Count
        $recordIndex++
    ) {
        $record = $records[$recordIndex]
        $displayIndex = $recordIndex + 1

        if ($null -eq $record) {
            throw "Rollback record $displayIndex is null."
        }

        foreach ($requiredProperty in $requiredProperties) {
            if (
                $record.PSObject.Properties.Name -notcontains
                $requiredProperty
            ) {
                throw (
                    "Rollback record $displayIndex is missing required " +
                    "property '$requiredProperty'."
                )
            }
        }

        $schemaVersion =
            [string]$record.SchemaVersion

        if (
            [string]::IsNullOrWhiteSpace(
                $schemaVersion
            )
        ) {
            throw (
                "Rollback record $displayIndex has an empty " +
                'SchemaVersion.'
            )
        }

        if ($schemaVersion -ne $supportedSchemaVersion) {
            throw (
                "Rollback record $displayIndex uses unsupported schema " +
                "version '$schemaVersion'. Supported version: " +
                "'$supportedSchemaVersion'."
            )
        }

        $deviceName =
            [string]$record.DeviceName

        if ([string]::IsNullOrWhiteSpace($deviceName)) {
            throw "Rollback record $displayIndex has an empty DeviceName."
        }

        $managedDeviceId =
            [string]$record.ManagedDeviceId

        $parsedManagedDeviceId =
            [guid]::Empty

        if (
            [string]::IsNullOrWhiteSpace(
                $managedDeviceId
            ) -or
            -not [guid]::TryParse(
                $managedDeviceId,
                [ref]$parsedManagedDeviceId
            )
        ) {
            throw (
                "Rollback record $displayIndex has an invalid " +
                "ManagedDeviceId '$managedDeviceId'."
            )
        }

        $previousUserId =
            [string]$record.PreviousUserId

        if (
            -not [string]::IsNullOrWhiteSpace(
                $previousUserId
            )
        ) {
            $parsedPreviousUserId =
                [guid]::Empty

            if (
                -not [guid]::TryParse(
                    $previousUserId,
                    [ref]$parsedPreviousUserId
                )
            ) {
                throw (
                    "Rollback record $displayIndex has an invalid " +
                    "PreviousUserId '$previousUserId'."
                )
            }
        }

        $newUserId =
            [string]$record.NewUserId

        if (
            -not [string]::IsNullOrWhiteSpace(
                $newUserId
            )
        ) {
            $parsedNewUserId =
                [guid]::Empty

            if (
                -not [guid]::TryParse(
                    $newUserId,
                    [ref]$parsedNewUserId
                )
            ) {
                throw (
                    "Rollback record $displayIndex has an invalid " +
                    "NewUserId '$newUserId'."
                )
            }
        }

        $timestampValue =
            [datetimeoffset]::MinValue

        if (
            -not [datetimeoffset]::TryParse(
                [string]$record.Timestamp,
                [ref]$timestampValue
            )
        ) {
            throw (
                "Rollback record $displayIndex has an invalid " +
                "Timestamp '$($record.Timestamp)'."
            )
        }

        $normalizedRecords.Add(
            [pscustomobject]@{
                SchemaVersion =
                    $schemaVersion

                SourcePath =
                    $resolvedPath

                RecordNumber =
                    $displayIndex

                DeviceName =
                    $deviceName

                ManagedDeviceId =
                    $parsedManagedDeviceId.ToString()

                PreviousUserId =
                    if (
                        [string]::IsNullOrWhiteSpace(
                            $previousUserId
                        )
                    ) {
                        $null
                    }
                    else {
                        ([guid]$previousUserId).ToString()
                    }

                PreviousUserPrincipal =
                    if (
                        [string]::IsNullOrWhiteSpace(
                            [string]$record.PreviousUserPrincipal
                        )
                    ) {
                        $null
                    }
                    else {
                        [string]$record.PreviousUserPrincipal
                    }

                NewUserId =
                    if (
                        [string]::IsNullOrWhiteSpace(
                            $newUserId
                        )
                    ) {
                        $null
                    }
                    else {
                        ([guid]$newUserId).ToString()
                    }

                NewUserPrincipal =
                    if (
                        [string]::IsNullOrWhiteSpace(
                            [string]$record.NewUserPrincipal
                        )
                    ) {
                        $null
                    }
                    else {
                        [string]$record.NewUserPrincipal
                    }

                RecommendedAction =
                    [string]$record.RecommendedAction

                RemediationStatus =
                    [string]$record.RemediationStatus

                VerificationStatus =
                    [string]$record.VerificationStatus

                Timestamp =
                    $timestampValue
            }
        )
    }

    return @($normalizedRecords)
}
