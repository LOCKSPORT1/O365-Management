function Get-ToolkitGroupMember {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Id', 'GroupId')]
        [string]$GroupId,

        [Parameter(Mandatory = $false)]
        [switch]$Recursive
    )

    process {
        Write-ToolkitLog -Message "Retrieving members for Entra group ID: $GroupId" -Level Information

        $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/members"
        
        try {
            $members = Invoke-ToolkitGraphPagedRequest -Uri $uri -ErrorAction Stop

            foreach ($member in $members) {
                [pscustomobject]@{
                    Id                = $member.id
                    DisplayName       = $member.displayName
                    UserPrincipalName = $member.userPrincipalName
                    Mail              = $member.mail
                    ODataType         = $member.'@odata.type'
                    GroupId           = $GroupId
                    RetrievedAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
                }
            }
        }
        catch {
            Write-ToolkitLog -Message "Failed to retrieve members for group $GroupId : $_" -Level Error
            throw $_
        }
    }
}