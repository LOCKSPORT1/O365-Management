# Entra and Azure scripts

## Entra-UserGroupMgmt.ps1
Supports listing group memberships, adding users to groups, and removing users from groups.

## Azure-SubscriptionContext.ps1
Connects to Azure and sets the current subscription context for follow-on operations.

### Multi-tenant usage
Use `TenantName` for identity context and optionally provide `SubscriptionId` for Azure context.


## Report-LicenseInventory.ps1
Builds a tenant license inventory from subscribed SKUs and can optionally include per-user assignments.


## Report-ConditionalAccessPolicies.ps1
Exports Conditional Access policy inventory through Microsoft Graph.

## Runbook examples
The `runbooks` folder contains an Azure Automation style orchestration example for unattended reporting.


## Report-PIMRoleAssignments.ps1
Exports directory role assignment inventory for PIM and role management review.
