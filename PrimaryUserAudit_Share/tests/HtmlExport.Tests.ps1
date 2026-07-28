BeforeAll {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot

    . (Join-Path `
        $ProjectRoot `
        "Private\Export-PrimaryUserAuditHtml.ps1")
}

Describe "Export-PrimaryUserAuditHtml" {
    BeforeEach {
        $TestOutputDirectory = Join-Path `
            $TestDrive `
            "Reports"

        $TestOutputPath = Join-Path `
            $TestOutputDirectory `
            "PrimaryUserAudit_Dashboard.html"

        $TestRecords = @(
            [pscustomobject]@{
                ManagedDeviceId             = "device-001"
                DeviceName                 = "PBI-001"
                EntraDeviceId              = "entra-001"
                SerialNumber               = "SERIAL001"
                Manufacturer               = "Dell"
                Model                      = "Latitude 5510"
                ComplianceState            = "compliant"
                LastSyncDateTime            = "2026-07-27 10:00:00"
                CurrentUserId              = "user-001"
                CurrentUserPrincipal       = "olduser@contoso.com"
                CurrentUserName            = "Old User"
                RecommendedUserId          = "user-002"
                RecommendedUserPrincipal   = "newuser@contoso.com"
                RecommendedUserName        = "New User"
                TotalSignIns               = 10
                LeadingUserSignIns         = 10
                SecondPlaceSignIns         = 0
                DominancePercent           = 100
                MinimumSignIns             = 5
                MinimumDominancePercent    = 70
                Confidence                 = "High"
                RecommendedAction          = "Change"
                CurrentUserMatches         = $false
                Reason                     = "A different user clearly dominates usage."
            }

            [pscustomobject]@{
                ManagedDeviceId             = "device-002"
                DeviceName                 = "PBI-002"
                EntraDeviceId              = "entra-002"
                SerialNumber               = "SERIAL002"
                Manufacturer               = "Lenovo"
                Model                      = "ThinkPad"
                ComplianceState            = "compliant"
                LastSyncDateTime            = "2026-07-27 11:00:00"
                CurrentUserId              = $null
                CurrentUserPrincipal       = $null
                CurrentUserName            = $null
                RecommendedUserId          = "user-003"
                RecommendedUserPrincipal   = "assigned@contoso.com"
                RecommendedUserName        = "Assigned User"
                TotalSignIns               = 8
                LeadingUserSignIns         = 8
                SecondPlaceSignIns         = 0
                DominancePercent           = 100
                MinimumSignIns             = 5
                MinimumDominancePercent    = 70
                Confidence                 = "High"
                RecommendedAction          = "Assign"
                CurrentUserMatches         = $false
                Reason                     = "No current user is assigned."
            }

            [pscustomobject]@{
                ManagedDeviceId             = "device-003"
                DeviceName                 = "PBI-003"
                EntraDeviceId              = "entra-003"
                SerialNumber               = "SERIAL003"
                Manufacturer               = "HP"
                Model                      = "EliteBook"
                ComplianceState            = "noncompliant"
                LastSyncDateTime            = "2026-07-27 12:00:00"
                CurrentUserId              = "user-004"
                CurrentUserPrincipal       = "review@contoso.com"
                CurrentUserName            = "Review User"
                RecommendedUserId          = "user-004"
                RecommendedUserPrincipal   = "review@contoso.com"
                RecommendedUserName        = "Review User"
                TotalSignIns               = 3
                LeadingUserSignIns         = 3
                SecondPlaceSignIns         = 0
                DominancePercent           = 100
                MinimumSignIns             = 5
                MinimumDominancePercent    = 70
                Confidence                 = "Low"
                RecommendedAction          = "Review"
                CurrentUserMatches         = $true
                Reason                     = "Not enough qualifying sign-ins."
            }

            [pscustomobject]@{
                ManagedDeviceId             = "device-004"
                DeviceName                 = "PBI-004"
                EntraDeviceId              = "entra-004"
                SerialNumber               = "SERIAL004"
                Manufacturer               = "Dell"
                Model                      = "OptiPlex"
                ComplianceState            = "compliant"
                LastSyncDateTime            = "2026-07-27 13:00:00"
                CurrentUserId              = "user-005"
                CurrentUserPrincipal       = "correct@contoso.com"
                CurrentUserName            = "Correct User"
                RecommendedUserId          = "user-005"
                RecommendedUserPrincipal   = "correct@contoso.com"
                RecommendedUserName        = "Correct User"
                TotalSignIns               = 12
                LeadingUserSignIns         = 12
                SecondPlaceSignIns         = 0
                DominancePercent           = 100
                MinimumSignIns             = 5
                MinimumDominancePercent    = 70
                Confidence                 = "High"
                RecommendedAction          = "NoChange"
                CurrentUserMatches         = $true
                Reason                     = "The current user matches observed usage."
            }

            [pscustomobject]@{
                ManagedDeviceId             = "device-005"
                DeviceName                 = "PBI-005"
                EntraDeviceId              = "entra-005"
                SerialNumber               = "SERIAL005"
                Manufacturer               = "Microsoft"
                Model                      = "Surface"
                ComplianceState            = "unknown"
                LastSyncDateTime            = "2026-07-27 14:00:00"
                CurrentUserId              = $null
                CurrentUserPrincipal       = $null
                CurrentUserName            = $null
                RecommendedUserId          = $null
                RecommendedUserPrincipal   = $null
                RecommendedUserName        = $null
                TotalSignIns               = 0
                LeadingUserSignIns         = 0
                SecondPlaceSignIns         = 0
                DominancePercent           = 0
                MinimumSignIns             = 5
                MinimumDominancePercent    = 70
                Confidence                 = "None"
                RecommendedAction          = "NoEvidence"
                CurrentUserMatches         = $false
                Reason                     = "No usable sign-in evidence was found."
            }
        )
    }

    It "creates an HTML dashboard file" {
        Export-PrimaryUserAuditHtml `
            -InputObject $TestRecords `
            -OutputPath $TestOutputPath

        Test-Path $TestOutputPath |
            Should -BeTrue
    }

    It "includes the dashboard title" {
        Export-PrimaryUserAuditHtml `
            -InputObject $TestRecords `
            -OutputPath $TestOutputPath `
            -Title "Test Primary User Audit"

        $Html = Get-Content `
            -Path $TestOutputPath `
            -Raw

        $Html |
            Should -Match "Test Primary User Audit"
    }

    It "includes every device record" {
        Export-PrimaryUserAuditHtml `
            -InputObject $TestRecords `
            -OutputPath $TestOutputPath

        $Html = Get-Content `
            -Path $TestOutputPath `
            -Raw

        foreach ($DeviceName in $TestRecords.DeviceName) {
            $Html |
                Should -Match ([regex]::Escape($DeviceName))
        }
    }

    It "counts each recommendation action correctly" {
        Export-PrimaryUserAuditHtml `
            -InputObject $TestRecords `
            -OutputPath $TestOutputPath

        $Html = Get-Content `
            -Path $TestOutputPath `
            -Raw

        $Html |
            Should -Match '<div class="card-value">5</div>'

        $Html |
            Should -Match '<div class="card-label">Change</div>'

        $Html |
            Should -Match '<div class="card-label">Assign</div>'

        $Html |
            Should -Match '<div class="card-label">Manual Review</div>'

        $Html |
            Should -Match '<div class="card-label">No Change</div>'

        $Html |
            Should -Match '<div class="card-label">No Evidence</div>'
    }

    It "maps Review actions to the manual review styling" {
        Export-PrimaryUserAuditHtml `
            -InputObject $TestRecords `
            -OutputPath $TestOutputPath

        $Html = Get-Content `
            -Path $TestOutputPath `
            -Raw

        $Html |
            Should -Match 'data-filter="Review"'

        $Html |
            Should -Match 'class="status manualreview">Review</span>'
    }

    It "HTML-encodes potentially unsafe values" {
        $UnsafeRecord = $TestRecords[0].PSObject.Copy()
        $UnsafeRecord.DeviceName = '<script>alert("test")</script>'

        Export-PrimaryUserAuditHtml `
            -InputObject @($UnsafeRecord) `
            -OutputPath $TestOutputPath

        $Html = Get-Content `
            -Path $TestOutputPath `
            -Raw

        $Html |
            Should -Not -Match '<script>alert\("test"\)</script>'

        $Html |
            Should -Match '&lt;script&gt;'
    }

    It "throws when no records are supplied" {
        {
            Export-PrimaryUserAuditHtml `
                -InputObject @() `
                -OutputPath $TestOutputPath
        } |
            Should -Throw
    }
}