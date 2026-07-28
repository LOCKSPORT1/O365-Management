BeforeAll {
    Remove-Module PrimaryUserAudit -Force -ErrorAction SilentlyContinue

    Import-Module `
        "$PSScriptRoot\..\PrimaryUserAudit.psd1" `
        -Force
}

Describe 'Invoke-PrimaryUserRemediation' {
    It 'is exported by the module' {
        Get-Command `
            -Name Invoke-PrimaryUserRemediation `
            -Module PrimaryUserAudit `
            -ErrorAction Stop |
        Should -Not -BeNullOrEmpty
    }

    It 'returns WhatIf for an eligible Change action' {
        $Recommendation = [pscustomobject]@{
            DeviceName              = 'PBI-TEST-001'
            CurrentPrimaryUser      = 'olduser@panelbuilt.com'
            RecommendedPrimaryUser  = 'newuser@panelbuilt.com'
            RecommendedAction       = 'Change'
        }

        $Result = $Recommendation |
            Invoke-PrimaryUserRemediation -WhatIf

        $Result.RemediationStatus | Should -Be 'WhatIf'
        $Result.RecommendedAction | Should -Be 'Change'
        $Result.Message | Should -Be 'No change was made.'
    }

    It 'returns WhatIf for an eligible Assign action' {
        $Recommendation = [pscustomobject]@{
            DeviceName              = 'PBI-TEST-002'
            CurrentPrimaryUser      = ''
            RecommendedPrimaryUser  = 'assigneduser@panelbuilt.com'
            RecommendedAction       = 'Assign'
        }

        $Result = $Recommendation |
            Invoke-PrimaryUserRemediation -WhatIf

        $Result.RemediationStatus | Should -Be 'WhatIf'
        $Result.RecommendedAction | Should -Be 'Assign'
    }

    It 'skips an ineligible NoChange action' {
        $Recommendation = [pscustomobject]@{
            DeviceName              = 'PBI-TEST-003'
            CurrentPrimaryUser      = 'user@panelbuilt.com'
            RecommendedPrimaryUser  = 'user@panelbuilt.com'
            RecommendedAction       = 'NoChange'
        }

        $Result = $Recommendation |
            Invoke-PrimaryUserRemediation -WhatIf

        $Result.RemediationStatus | Should -Be 'Skipped'
        $Result.Message |
            Should -Be "Action 'NoChange' is not eligible for remediation."
    }

    It 'skips a Review action' {
        $Recommendation = [pscustomobject]@{
            DeviceName              = 'PBI-TEST-004'
            CurrentPrimaryUser      = 'user1@panelbuilt.com'
            RecommendedPrimaryUser  = 'user2@panelbuilt.com'
            RecommendedAction       = 'Review'
        }

        $Result = $Recommendation |
            Invoke-PrimaryUserRemediation -WhatIf

        $Result.RemediationStatus | Should -Be 'Skipped'
    }

    It 'throws when DeviceName is missing' {
        $Recommendation = [pscustomobject]@{
            DeviceName              = ''
            CurrentPrimaryUser      = 'olduser@panelbuilt.com'
            RecommendedPrimaryUser  = 'newuser@panelbuilt.com'
            RecommendedAction       = 'Change'
        }

        {
            $Recommendation |
                Invoke-PrimaryUserRemediation -WhatIf
        } | Should -Throw 'Each recommendation must contain a DeviceName.'
    }

    It 'processes multiple recommendation records' {
        $Recommendations = @(
            [pscustomobject]@{
                DeviceName              = 'PBI-TEST-001'
                CurrentPrimaryUser      = 'olduser@panelbuilt.com'
                RecommendedPrimaryUser  = 'newuser@panelbuilt.com'
                RecommendedAction       = 'Change'
            },
            [pscustomobject]@{
                DeviceName              = 'PBI-TEST-002'
                CurrentPrimaryUser      = ''
                RecommendedPrimaryUser  = 'assigneduser@panelbuilt.com'
                RecommendedAction       = 'Assign'
            },
            [pscustomobject]@{
                DeviceName              = 'PBI-TEST-003'
                CurrentPrimaryUser      = 'user@panelbuilt.com'
                RecommendedPrimaryUser  = 'user@panelbuilt.com'
                RecommendedAction       = 'NoChange'
            }
        )

        $Result = $Recommendations |
            Invoke-PrimaryUserRemediation -WhatIf

        $Result.Count | Should -Be 3
        ($Result |
            Where-Object RemediationStatus -eq 'WhatIf').Count |
        Should -Be 2

        ($Result |
            Where-Object RemediationStatus -eq 'Skipped').Count |
        Should -Be 1
    }
}
