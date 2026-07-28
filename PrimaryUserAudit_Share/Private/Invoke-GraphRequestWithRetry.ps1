function Invoke-GraphRequestWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter()]
        [ValidateSet('GET','POST','PUT','PATCH','DELETE')]
        [string]$Method = 'GET'
    )

    Write-Verbose "Invoke-GraphRequestWithRetry called"

    try {
        Invoke-MgGraphRequest `
            -Method $Method `
            -Uri $Uri `
            -OutputType PSObject `
            -ErrorAction Stop
    }
    catch {
        throw "Graph request failed: $($_.Exception.Message)"
    }
}