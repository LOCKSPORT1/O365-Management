function Invoke-PrimaryUserRemediation {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param (
        [Parameter(
            Mandatory = $true,
            ValueFromPipeline = $true
        )]
        [ValidateNotNullOrEmpty()]
        [object[]]$Recommendation,

        [Parameter()]
        [ValidateSet('Assign', 'Change')]
        [string[]]$AllowedAction = @(
            'Assign',
            'Change'
        )
    )

    begin {
        $Results = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($Item in $Recommendation) {
            $DeviceName = [string]$Item.DeviceName
            $Action = [string]$Item.RecommendedAction
            $CurrentUser = [string]$Item.CurrentPrimaryUser
            $RecommendedUser = [string]$Item.RecommendedPrimaryUser

            if ([string]::IsNullOrWhiteSpace($DeviceName)) {
                throw 'Each recommendation must contain a DeviceName.'
            }

            if ($Action -notin $AllowedAction) {
                $Results.Add(
                    [pscustomobject]@{
                        DeviceName             = $DeviceName
                        CurrentPrimaryUser      = $CurrentUser
                        RecommendedPrimaryUser  = $RecommendedUser
                        RecommendedAction       = $Action
                        RemediationStatus       = 'Skipped'
                        Message                 = "Action '$Action' is not eligible for remediation."
                    }
                )

                continue
            }

            $Target = "$DeviceName : $CurrentUser -> $RecommendedUser"
            $Operation = "Apply Intune Primary User action '$Action'"

            if ($PSCmdlet.ShouldProcess($Target, $Operation)) {
                $Results.Add(
                    [pscustomobject]@{
                        DeviceName             = $DeviceName
                        CurrentPrimaryUser      = $CurrentUser
                        RecommendedPrimaryUser  = $RecommendedUser
                        RecommendedAction       = $Action
                        RemediationStatus       = 'NotImplemented'
                        Message                 = 'Graph remediation is not enabled yet.'
                    }
                )
            }
            else {
                $Results.Add(
                    [pscustomobject]@{
                        DeviceName             = $DeviceName
                        CurrentPrimaryUser      = $CurrentUser
                        RecommendedPrimaryUser  = $RecommendedUser
                        RecommendedAction       = $Action
                        RemediationStatus       = 'WhatIf'
                        Message                 = 'No change was made.'
                    }
                )
            }
        }
    }

    end {
        return $Results
    }
}
