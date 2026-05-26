# Create Azure Subscription Script

## Warning

Use this script at your own risk.

This script can create subscriptions, move subscriptions between management groups, create Entra ID groups, configure networking, change Defender pricing plans, and send operational email. Running it with incorrect configuration or excessive permissions can cause broad impact in your Azure tenant.

Always test in a non-production tenant or sandbox first.

## Purpose

This repository contains a PowerShell script that automates Azure subscription vending through Azure Automation.

Main outcomes:

1. Creates a new Azure subscription.
2. Applies naming conventions.
3. For network enabled subscriptions, reserves IP space in an external IPAM solution and provisions core network resources
4. Moves the subscription to a target management group.
5. Creates Entra ID groups and optional PIM group/policies for production.
6. Sends a notification email with generated RBAC snippet.
7. Enables key Defender for Cloud plans.

## How This Runs In Azure Automation

The script is designed to run as an Azure Automation runbook using a system-assigned managed identity.

Authentication in the script:

1. Connects to Azure Resource Manager with managed identity.
2. Connects to Microsoft Graph with managed identity.

Because of this, no user credentials are required inside the runbook, but the managed identity must be granted all required permissions.

## Required Permissions

Grant least privilege where possible, but the identity must be able to complete all operations below.

### Azure control-plane permissions

1. Create subscription alias and subscription.
2. Read and select subscriptions.
3. Move subscription to management group.
4. Register resource providers in the new subscription.
5. Create resource group, vNet, private DNS zone, and DNS links.
6. Create virtual hub connection in connectivity subscription.
7. Read secrets from Key Vault used for IPAM credentials.
8. Set Defender for Cloud pricing plans.

Typical scopes involved:

1. Billing scope for alias creation.
2. Management group scope for subscription move.
3. Automation subscription scope for Key Vault access.
4. Connectivity subscription scope for vHub connection.
5. Newly created subscription scope for resource provisioning.

### Microsoft Graph permissions

1. Read users by mail.
2. Read/create groups.
3. Add group owners.
4. Configure PIM policy rules for group membership (production path).
5. Create privileged access eligibility schedule request.
6. Send email from configured mailbox account.

Important:

1. Graph permissions must be consented for the managed identity app registration.
2. If any Graph scope is missing, group creation/PIM/email steps will fail.

## Required PowerShell Modules In Azure Automation

Install/import these modules in the Automation Account used by the runbook.

### Az modules

1. Az.Accounts
2. Az.Subscription
3. Az.Resources
4. Az.Network
5. Az.KeyVault
6. Az.Security

### Microsoft Graph modules

1. Microsoft.Graph.Authentication
2. Microsoft.Graph.Users
3. Microsoft.Graph.Groups
4. Microsoft.Graph.Identity.Governance
5. Microsoft.Graph.Users.Actions
6. Microsoft.Graph.Identity.SignIns

### External IPAM module

The script currently calls IPAM commands directly:

1. Connect-IPAM
2. Get-IPAMNetworkNextAvailableNetwork
3. Get-IPAMNetwork
4. Add-IPAMNetwork
5. Disconnect-IPAM

You must provide/import a module that exposes those commands in the Automation runtime.

## Script Inputs

Required parameters:

1. GroupName
2. Environment
3. WhoIsOwner

WhoIsOwner is expected as comma-separated email addresses.

Example:

1. GroupName = platformdata
2. Environment = p
3. WhoIsOwner = owner1(at)contoso.com,owner2(at)contoso.com

## Environment Mapping Logic

Environment is matched by prefix and translated to internal config values:

1. ep -> Ext-Prod, mg-OnlineProduction, Production
2. ea -> Ext-Accp, mg-OnlineNonProduction, DevTest
3. et -> Ext-Test, mg-OnlineNonProduction, DevTest
4. eo -> Ext-Ontw, mg-OnlineNonProduction, DevTest
5. p -> Prod, mg-CorpProduction, Production
6. a -> Accp, mg-CorpNonProduction, DevTest
7. t -> Test, mg-CorpNonProduction, DevTest
8. o -> Ontw, mg-CorpNonProduction, DevTest
9. s -> Sandbox, mg-Sandbox, DevTest
10. g -> Other, mg-Other, DevTest

If no valid mapping is found, the script exits.

## Configuration Placeholders You Must Replace

Before production usage, replace placeholders at the top of the script:

1. billing-scope
2. shared-services-vnet-resource-id
3. automation-subscription-id
4. secrets-vault-name
5. connectivity-subscription-id
6. ipam-server.example.com
7. ipam-api-version
8. internal-doc-url
9. rbac-repository-url

Also confirm:

1. IPAM configuration and secret names in Key Vault.
2. Mailbox sender and recipient addresses.
3. DNS and network ranges.

## In-Depth Execution Flow

### 1. Initialization and normalization

1. Reads runbook parameters.
2. Normalizes GroupName to lowercase alphanumeric token.
3. Derives suffix and naming components.

### 2. Environment and workload resolution

1. Maps Environment prefix to management group and workload type.
2. Sets production/non-production behavior flags implicitly through selected management group.

### 3. Naming construction

1. Entra base group name: grp.az.[normalized-group].[environment]
2. Optional PIM group: base group plus .pim
3. Subscription name: [normalized-group]-[environment]-001

### 4. IPAM allocation

For mg-CorpProduction and mg-CorpNonProduction only:

1. Connects to automation subscription.
2. Reads IPAM credentials from Key Vault.
3. Connects to IPAM service.
4. Requests next available network block.
5. Validates block is not already present.
6. Reserves block with subscription name comment.

### 5. Subscription creation

1. Calls New-AzSubscriptionAlias with BillingScope and workload type.
2. Polls Get-AzSubscription up to 30 attempts with 10-second delay.
3. Exits on timeout.

### 6. Provider registration

Registers required providers in the new subscription:

1. Microsoft.Security
2. Microsoft.PolicyInsights
3. Microsoft.Maintenance
4. Microsoft.DataProtection

### 7. Network provisioning path

Skipped for sandbox, other, and external management group targets.

For internal targets:

1. Creates network resource group.
2. Creates vNet with reserved address space.
3. Creates private DNS zone.
4. Links DNS zone to local vNet.
5. Links DNS zone to shared-services vNet.
6. Creates vHub vNet connection in connectivity subscription.

### 8. Management group placement

Moves the created subscription into the correct management group.

### 9. Entra group and owner handling

1. Connects to Microsoft Graph with managed identity.
2. Creates or reuses base Entra group.
3. Adds each owner from WhoIsOwner if user exists.

### 10. Production-only PIM logic

For mg-CorpProduction:

1. Creates or reuses PIM group.
2. Applies PIM rules (expiration, approval, enablement, notification).
3. Adds base group as eligible member of PIM group.
4. Reapplies PIM rules later as validation step.

### 11. Email output

Builds and sends HTML email containing:

1. Subscription details.
2. Group and workload info.
3. Network info or skip explanation.
4. Generated RBAC snippet for downstream IaC.

### 12. Defender for Cloud enablement

Applies Standard pricing for key Defender plans such as:

1. VirtualMachines
2. SqlServers
3. AppServices
4. StorageAccounts (DefenderForStorageV2)
5. SqlServerVirtualMachines
6. KeyVaults
7. OpenSourceRelationalDatabases
8. Containers
9. CosmosDbs
10. CloudPosture
11. Arm

## Operational Notes

1. The script is not idempotent for every operation. Review behavior carefully before re-running.
2. IPAM reservation and subscription creation timing can produce transient failures.
3. Ensure Graph connectivity and permissions are available in Automation runtime.
4. Validate sender mailbox rights for Send-MgUserMail.
5. Keep module versions aligned and tested in a staging Automation account.

## Recommended Safe Rollout

1. Run in a test tenant first.
2. Start with non-production environment code.
3. Validate group creation, network, and mail output.
4. Validate RBAC snippet integration in your IaC repo.
5. Promote to production only after successful dry-runs.

## Appendix Permissions

By default, an Automation Account cannot do anything. To perform the actions described above (following the least-privileged model), a system-assigned managed identity was created in Azure Automation with the permissions below.

### Permissions on the landing zone

On all landing zone subscriptions, the managed identity has Owner permissions, because otherwise it cannot create the networking components and related links.

### Permissions to create subscriptions

In Cost Management + Billing, the managed identity has Azure Subscription Creator permissions on the ANWB generic invoice section.

### Permissions for Entra ID groups and PIM policies

To create Entra ID groups with PIM policies, assign an owner, and send email, the permissions below were configured (these can only be added through the Azure CLI).

```powershell
$ServicePrincipalId = '57435c97-9d36-4b1c-8d70-e0b87ad27e42'
$GraphResource = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
$Permission = $GraphResource.AppRoles | Where-Object {$_.value -eq 'User.Read.All'}
New-AzureADServiceAppRoleAssignment -ObjectId $ServicePrincipalId -PrincipalId $ServicePrincipalId -Id $Permission.Id -ResourceId $GraphResource.ObjectId
$ServicePrincipalId = '57435c97-9d36-4b1c-8d70-e0b87ad27e42'
$GraphResource = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
$Permission = $GraphResource.AppRoles | Where-Object {$_.value -eq 'Group.ReadWrite.All'}
New-AzureADServiceAppRoleAssignment -ObjectId $ServicePrincipalId -PrincipalId $ServicePrincipalId -Id $Permission.Id -ResourceId $GraphResource.ObjectId
$ServicePrincipalId = '57435c97-9d36-4b1c-8d70-e0b87ad27e42'
$GraphResource = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
$Permission = $GraphResource.AppRoles | Where-Object {$_.value -eq 'User.ReadWrite.All'}
New-AzureADServiceAppRoleAssignment -ObjectId $ServicePrincipalId -PrincipalId $ServicePrincipalId -Id $Permission.Id -ResourceId $GraphResource.ObjectId
$ServicePrincipalId = '57435c97-9d36-4b1c-8d70-e0b87ad27e42'
$GraphResource = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
$Permission = $GraphResource.AppRoles | Where-Object {$_.value -eq 'PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup'}
New-AzureADServiceAppRoleAssignment -ObjectId $ServicePrincipalId -PrincipalId $ServicePrincipalId -Id $Permission.Id -ResourceId $GraphResource.ObjectId
$ServicePrincipalId = '57435c97-9d36-4b1c-8d70-e0b87ad27e42'
$GraphResource = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
$Permission = $GraphResource.AppRoles | Where-Object {$_.value -eq 'Domain.Read.All'}
New-AzureADServiceAppRoleAssignment -ObjectId $ServicePrincipalId -PrincipalId $ServicePrincipalId -Id $Permission.Id -ResourceId $GraphResource.ObjectId
$ServicePrincipalId = '57435c97-9d36-4b1c-8d70-e0b87ad27e42'
$GraphResource = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
$Permission = $GraphResource.AppRoles | Where-Object {$_.value -eq 'RoleManagementPolicy.ReadWrite.AzureADGroup'}
New-AzureADServiceAppRoleAssignment -ObjectId $ServicePrincipalId -PrincipalId $ServicePrincipalId -Id $Permission.Id -ResourceId $GraphResource.ObjectId
$ServicePrincipalId = '57435c97-9d36-4b1c-8d70-e0b87ad27e42'
$GraphResource = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
$Permission = $GraphResource.AppRoles | Where-Object {$_.value -eq 'PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup'}
New-AzureADServiceAppRoleAssignment -ObjectId $ServicePrincipalId -PrincipalId $ServicePrincipalId -Id $Permission.Id -ResourceId $GraphResource.ObjectId
$ServicePrincipalId = '57435c97-9d36-4b1c-8d70-e0b87ad27e42'
$GraphResource = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
$Permission = $GraphResource.AppRoles | Where-Object {$_.value -eq 'PrivilegedAccess.ReadWrite.AzureADGroup'}
New-AzureADServiceAppRoleAssignment -ObjectId $ServicePrincipalId -PrincipalId $ServicePrincipalId -Id $Permission.Id -ResourceId $GraphResource.ObjectId
$ServicePrincipalId = '57435c97-9d36-4b1c-8d70-e0b87ad27e42'
$GraphResource = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
$Permission = $GraphResource.AppRoles | Where-Object {$_.value -eq 'PrivilegedEligibilitySchedule.Remove.AzureADGroup'}
New-AzureADServiceAppRoleAssignment -ObjectId $ServicePrincipalId -PrincipalId $ServicePrincipalId -Id $Permission.Id -ResourceId $GraphResource.ObjectId
$ServicePrincipalId = '57435c97-9d36-4b1c-8d70-e0b87ad27e42'
$GraphResource = Get-AzureADServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
$Permission = $GraphResource.AppRoles | Where-Object {$_.value -eq 'Mail.Send'}
New-AzureADServiceAppRoleAssignment -ObjectId $ServicePrincipalId -PrincipalId $ServicePrincipalId -Id $Permission.Id -ResourceId $GraphResource.ObjectId
```