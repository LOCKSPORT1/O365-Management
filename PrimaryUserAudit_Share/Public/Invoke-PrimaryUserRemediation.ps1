function Invoke-PrimaryUserRemediation {
    <#
    .SYNOPSIS
        Applies approved Intune primary-user recommendations.

    .DESCRIPTION
        Processes primary-user audit recommendation records.

        Only Assign and Change actions are eligible by default. The function
        supports WhatIf and Confirm through PowerShell ShouldProcess.

        Eligible actions call Set-IntunePrimaryUser only after ShouldProcess
        approves the operation.

    .PARAMETER Recommendation
        One or more recommendation objects produced by the primary-user audit.

    .PARAMETER AllowedAction
        Recommendation actions that may be remediated.

    .EXAMPLE
        $Recommendations |
            Invoke-PrimaryUserRemediation -WhatIf

    .EXAMPLE
        $Recommendations |
            Invoke-PrimaryUserRemediation -Confirm:$false
    #>

    [CmdletBinding(
        SupportsShouldProcess = $true,
        ConfirmImpact = 'High'
    )]
    param(
        [Parameter(
            Mandatory,
            ValueFromPipeline
        )]
        [ValidateNotNullOrEmpty()]
        [object[]]$Recommendation,

        [Parameter()]
        [ValidateSet(
            'Assign',
            'Change'
        )]
        [string[]]$AllowedAction = @(
            'Assign',
            'Change'
        )
    )

    begin {
        Set-StrictMode -Version Latest

        $results =
            [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $Recommendation) {
            $deviceName =
                [string]$item.DeviceName

            $managedDeviceId =
                [string]$item.ManagedDeviceId

            $action =
                [string]$item.RecommendedAction

            $currentUserPrincipal =
                if (
                    $item.PSObject.Properties.Name -contains
                    'CurrentUserPrincipal'
                ) {
                    [string]$item.CurrentUserPrincipal
                }
                elseif (
                    $item.PSObject.Properties.Name -contains
                    'CurrentPrimaryUser'
                ) {
                    [string]$item.CurrentPrimaryUser
                }
                else {
                    ''
                }

            $recommendedUserPrincipal =
                if (
                    $item.PSObject.Properties.Name -contains
                    'RecommendedUserPrincipal'
                ) {
                    [string]$item.RecommendedUserPrincipal
                }
                elseif (
                    $item.PSObject.Properties.Name -contains
                    'RecommendedPrimaryUser'
                ) {
                    [string]$item.RecommendedPrimaryUser
                }
                else {
                    ''
                }

            $recommendedUserId =
                [string]$item.RecommendedUserId

            if (
                [string]::IsNullOrWhiteSpace(
                    $deviceName
                )
            ) {
                throw (
                    'Each recommendation must contain a DeviceName.'
                )
            }

            if ($action -notin $AllowedAction) {
                $results.Add(
                    [pscustomobject]@{
                        DeviceName =
                            $deviceName

                        ManagedDeviceId =
                            $managedDeviceId

                        CurrentUserPrincipal =
                            $currentUserPrincipal

                        RecommendedUserPrincipal =
                            $recommendedUserPrincipal

                        RecommendedUserId =
                            $recommendedUserId

                        RecommendedAction =
                            $action

                        RemediationStatus =
                            'Skipped'

                        Message =
                            "Action '$action' is not eligible for remediation."

                        GraphRequest =
                            $null

                        ErrorMessage =
                            $null
                    }
                )

                continue
            }

            if (
                [string]::IsNullOrWhiteSpace(
                    $managedDeviceId
                )
            ) {
                throw (
                    "Recommendation for device '$deviceName' " +
                    'must contain ManagedDeviceId.'
                )
            }

            if (
                -not [guid]::TryParse(
                    $managedDeviceId,
                    [ref]([guid]::Empty)
                )
            ) {
                throw (
                    "ManagedDeviceId for device '$deviceName' " +
                    'must be a valid GUID.'
                )
            }

            if (
                [string]::IsNullOrWhiteSpace(
                    $recommendedUserId
                )
            ) {
                throw (
                    "Recommendation for device '$deviceName' " +
                    'must contain RecommendedUserId.'
                )
            }

            if (
                -not [guid]::TryParse(
                    $recommendedUserId,
                    [ref]([guid]::Empty)
                )
            ) {
                throw (
                    "RecommendedUserId for device '$deviceName' " +
                    'must be a valid GUID.'
                )
            }

            $target = (
                "$deviceName : " +
                "$currentUserPrincipal -> " +
                $recommendedUserPrincipal
            )

            $operation = (
                "Apply Intune Primary User action '$action'"
            )

            if (
                -not $PSCmdlet.ShouldProcess(
                    $target,
                    $operation
                )
            ) {
                $results.Add(
                    [pscustomobject]@{
                        DeviceName =
                            $deviceName

                        ManagedDeviceId =
                            $managedDeviceId

                        CurrentUserPrincipal =
                            $currentUserPrincipal

                        RecommendedUserPrincipal =
                            $recommendedUserPrincipal

                        RecommendedUserId =
                            $recommendedUserId

                        RecommendedAction =
                            $action

                        RemediationStatus =
                            'WhatIf'

                        Message =
                            'No change was made.'

                        GraphRequest =
                            $null

                        ErrorMessage =
                            $null
                    }
                )

                continue
            }

            try {
                $graphRequest =
                    Set-IntunePrimaryUser `
                        -ManagedDeviceId $managedDeviceId `
                        -UserId $recommendedUserId `
                        -Execute `
                        -Verbose:$VerbosePreference

                $results.Add(
                    [pscustomobject]@{
                        DeviceName =
                            $deviceName

                        ManagedDeviceId =
                            $managedDeviceId

                        CurrentUserPrincipal =
                            $currentUserPrincipal

                        RecommendedUserPrincipal =
                            $recommendedUserPrincipal

                        RecommendedUserId =
                            $recommendedUserId

                        RecommendedAction =
                            $action

                        RemediationStatus =
                            'Completed'

                        Message =
                            'Intune primary user assignment completed.'

                        GraphRequest =
                            $graphRequest

                        ErrorMessage =
                            $null
                    }
                )
            }
            catch {
                $results.Add(
                    [pscustomobject]@{
                        DeviceName =
                            $deviceName

                        ManagedDeviceId =
                            $managedDeviceId

                        CurrentUserPrincipal =
                            $currentUserPrincipal

                        RecommendedUserPrincipal =
                            $recommendedUserPrincipal

                        RecommendedUserId =
                            $recommendedUserId

                        RecommendedAction =
                            $action

                        RemediationStatus =
                            'Failed'

                        Message =
                            'Intune primary user assignment failed.'

                        GraphRequest =
                            $null

                        ErrorMessage =
                            $_.Exception.Message
                    }
                )
            }
        }
    }

    end {
        return $results
    }
}
