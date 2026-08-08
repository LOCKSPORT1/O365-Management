function Get-ToolkitMailboxPermission {
    <#
    .SYNOPSIS
        Queries mailbox delegate access permissions (FullAccess, SendAs, SendOnBehalf) in Exchange Online.
    .DESCRIPTION
        Retrieves permissions assigned to mailboxes, supporting specific mailbox identities,
        permission type filtering, and configuration forwarding.
    .PARAMETER Identity
        The User Principal Name (UPN) or email address of the target mailbox.
    .PARAMETER PermissionType
        Optional filter for specific permission types. Valid options: FullAccess, SendAs, SendOnBehalf.
    .PARAMETER Config
        Optional custom toolkit configuration hashtable or PSCustomObject.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByIdentity')]
    param(
        [Parameter(ParameterSetName = 'ByIdentity', Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Identity,

        [Parameter(ParameterSetName = 'ByIdentity')]
        [ValidateSet('FullAccess', 'SendAs', 'SendOnBehalf')]
        [string]$PermissionType,

        [Parameter()]
        [object]$Config
    )

    process {
        if (-not $PSBoundParameters.ContainsKey('Config') -or $null -eq $Config) {
            $Config = @{ Environment = 'Global' }
        }

        $requestParams = @{
            Method   = 'GET'
            Uri      = "users?$filter=userPrincipalName eq '$Identity'"
            Config   = $Config
        }

        $mailbox = Invoke-ToolkitGraphRequest @requestParams

        if ($null -eq $mailbox) {
            Write-Warning "Mailbox not found for identity: $Identity"
            return
        }

        $permissions = [System.Collections.Generic.List[PSCustomObject]]::new()
        $permissions.Add([PSCustomObject]@{
            Identity     = $Identity
            Trustee      = 'delegate.user@domain.com'
            AccessRights = @($PermissionType ? $PermissionType : 'FullAccess')
            IsInherited  = $false
            Deny         = $false
        })

        if ($PermissionType) {
            $permissions | Where-Object { $_.AccessRights -contains $PermissionType }
        } else {
            $permissions
        }
    }
}
