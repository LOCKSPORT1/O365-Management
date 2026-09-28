<#
    Environment settings for the neutral script variants.

    Copy to environment.psd1 beside the scripts and fill in. The neutral
    variants read this at startup; the preset variants keep their
    values inline, which is the only difference between the two sets.

    Every value here is a default. Each script still accepts the equivalent
    parameter, and an explicit parameter always wins.
#>
@{

    # Distinguished name of the OU holding shared mailbox objects.
    # Used by the offboarding and shared-mailbox audit scripts.
    #   Example: 'OU=Shared Mailboxes,OU=Company Users,DC=contoso,DC=local'
    SharedMailboxOU     = ''

    # Distinguished name of the OU new hires are created in.
    #   Example: 'OU=New Users,DC=contoso,DC=local'
    NewUserOU           = ''

    # UPN suffix for new accounts. Must be a verified domain in the tenant.
    #   Example: 'contoso.com'
    UpnSuffix           = ''

    # Hostname of the Entra Connect (Azure AD Connect) server. Used to trigger
    # a delta sync over PowerShell remoting after an AD change.
    # Leave empty in a cloud-only environment; the sync stage is skipped.
    EntraConnectServer  = ''

    # Default usage location for new accounts, as an ISO 3166-1 alpha-2 code.
    # Licences cannot be assigned without one.
    UsageLocation       = 'US'
}
