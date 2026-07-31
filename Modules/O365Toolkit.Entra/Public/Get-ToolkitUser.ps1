function Get-ToolkitUser {
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [psobject]$Config,

        [Parameter(
            Mandatory,
            ParameterSetName = 'ByUserPrincipalName'
        )]
        [ValidateNotNullOrEmpty()]
        [string]$UserPrincipalName,

        [Parameter(
            Mandatory,
            ParameterSetName = 'ByDepartment'
        )]
        [ValidateNotNullOrEmpty()]
        [string]$Department,

        [Parameter(ParameterSetName = 'All')]
        [Parameter(ParameterSetName = 'ByDepartment')]
        [switch]$LicensedOnly,

        [Parameter()]
        [ValidateRange(1, 20)]
        [int]$MaxAttempts = 4,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$MaximumRetryDelaySeconds = 60,

        [Parameter()]
        [switch]$PassThru
    )

    $selectProperties = @(
        'id'
        'displayName'
        'userPrincipalName'
        'mail'
        'accountEnabled'
        'userType'
        'department'
        'jobTitle'
        'companyName'
        'officeLocation'
        'createdDateTime'
        'assignedLicenses'
    )

    $selectQuery = $selectProperties -join ','

    switch ($PSCmdlet.ParameterSetName) {
        'ByUserPrincipalName' {
            $escapedUpn = [uri]::EscapeDataString(
                $UserPrincipalName
            )

            $uri = (
                'https://graph.microsoft.com/v1.0/users/' +
                "${escapedUpn}?`$select=$selectQuery"
            )

            $request = Invoke-ToolkitGraphRequest `
                -Method GET `
                -Uri $uri `
                -Config $Config `
                -MaxAttempts $MaxAttempts `
                -MaximumRetryDelaySeconds $MaximumRetryDelaySeconds `
                -PassThru

            if ($PassThru) {
                return [pscustomobject]@{
                    Success             = $request.Success
                    QueryType           = 'UserPrincipalName'
                    UserPrincipalName   = $UserPrincipalName
                    DurationMs          = $request.DurationMs
                    RecordCount         = 1
                    Data                = $request.Data
                }
            }

            return $request.Data
        }

        default {
            $uri = (
                'https://graph.microsoft.com/v1.0/users' +
                "?`$select=$selectQuery"
            )

            $request = Invoke-ToolkitGraphRequest `
                -Method GET `
                -Uri $uri `
                -Config $Config `
                -AllPages `
                -MaxAttempts $MaxAttempts `
                -MaximumRetryDelaySeconds $MaximumRetryDelaySeconds `
                -PassThru

            $users = @($request.Data)

            if (
                $PSCmdlet.ParameterSetName -eq 'ByDepartment'
            ) {
                $users = @(
                    $users |
                    Where-Object {
                        $_.department -eq $Department
                    }
                )
            }

            if ($LicensedOnly) {
                $users = @(
                    $users |
                    Where-Object {
                        @($_.assignedLicenses).Count -gt 0
                    }
                )
            }

            if ($PassThru) {
                return [pscustomobject]@{
                    Success      = $request.Success
                    QueryType    = $PSCmdlet.ParameterSetName
                    Department   = $Department
                    LicensedOnly = [bool]$LicensedOnly
                    DurationMs   = $request.DurationMs
                    PageCount    = $request.PageCount
                    RecordCount  = $users.Count
                    Data         = $users
                }
            }

            return $users
        }
    }
}
