Param
(
  [Parameter (Mandatory= $true)]
  [String] $GroupName,

  [Parameter (Mandatory= $true)]
  [String] $Environment,

  [Parameter (Mandatory= $true)]
  [String] $WhoIsOwner

)

$PSStyle.OutputRendering = [System.Management.Automation.OutputRendering]::PlainText;

function LogMessage
{
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [string]$LogMessage
    )

    Write-Output ("{0} - {1}" -f (Get-Date -Format "dd-MM-yyyy HH:mm:ss K"), $LogMessage)
}

LogMessage "Script started"

# Initialize base variables used across naming, environment mapping, and generated output.
# These values are reused later in resource names, email content, and control flow, so they are defined upfront for consistency and ease of maintenance.
$Managementgroupname = $GroupName
$subnumber = "1"
$pre = "<pre>"

# Normalize the management group input so generated names are deterministic and policy-compliant.
# This strips non-alphanumeric characters and enforces lowercase.
$MGidname = [regex]::Replace(($Managementgroupname -as [string]).Trim().ToLowerInvariant(), '[^a-z0-9]', '')

$Environment = $Environment.ToLower()

# Map short environment input to a canonical suffix, parent management group, and workload type.
# Prefix matching allows users to pass short codes while keeping policy targets explicit.
$envConfig = $null
switch -regex ($Environment) {
    '^ep' { $envConfig = @{ omgeving = 'Ext-Prod'; parent = 'mg-OnlineProduction'; type = 'Production' }; break }
    '^ea' { $envConfig = @{ omgeving = 'Ext-Accp'; parent = 'mg-OnlineNonProduction'; type = 'DevTest' }; break }
    '^et' { $envConfig = @{ omgeving = 'Ext-Test'; parent = 'mg-OnlineNonProduction'; type = 'DevTest' }; break }
    '^eo' { $envConfig = @{ omgeving = 'Ext-Ontw'; parent = 'mg-OnlineNonProduction'; type = 'DevTest' }; break }
    '^p'  { $envConfig = @{ omgeving = 'Prod'; parent = 'mg-CorpProduction'; type = 'Production' }; break }
    '^a'  { $envConfig = @{ omgeving = 'Accp'; parent = 'mg-CorpNonProduction'; type = 'DevTest' }; break }
    '^t'  { $envConfig = @{ omgeving = 'Test'; parent = 'mg-CorpNonProduction'; type = 'DevTest' }; break }
    '^o'  { $envConfig = @{ omgeving = 'Ontw'; parent = 'mg-CorpNonProduction'; type = 'DevTest' }; break }
    '^s'  { $envConfig = @{ omgeving = 'Sandbox'; parent = 'mg-Sandbox'; type = 'DevTest' }; break }
    '^g'  { $envConfig = @{ omgeving = 'Other'; parent = 'mg-Other'; type = 'DevTest' }; break }
}


if (-not $envConfig) {
    LogMessage "Script stopped because no valid environment code was supplied"
    LogMessage "Valid internal environments are: a = Acceptance, o = Development, p = Production, s = Sandbox, t = Test, and g = Other"
    LogMessage "Valid external environments are: ea = External Acceptance, eo = External Development, ep = External Production, et = External Test"
    exit 1
}

$Environment = $envConfig.omgeving
$parentmanagementgroup = $envConfig.parent
$subscriptiontype = $envConfig.type

# Build Entra group names from a stable naming convention.
# Production subscriptions receive an additional PIM group with a fixed suffix.
$azuremgtgroup = "grp.az."+$MGidname+'.'+$Environment
$azuremgtgroup = $azuremgtgroup.ToLower()
$pimsuffix = ".pim"
$azuremgtgrouppim = $azuremgtgroup + $pimsuffix

# Build subscription name from normalized group, environment, and sequence number.
$subscriptionName = $MGidname+'-'+$Environment+'-'+$subnumber
$subscriptionName = $subscriptionName.ToLower()

# Set subscription guid needed for New-AzSubscriptionAlias AliasName
$subscriptionGuid = New-Guid

# Define runtime configuration values for billing, networking, and external system integration.
# These placeholders are intentionally generic for public repository usage.
$subbillingscope = "<billing-scope>"
$virtualNetworkResourceGroupName = "rg-network-$subscriptionName"
$virtualNetworkName = "vnet-$subscriptionName"
$virtualNetworkPrivateDNSName  = "$subscriptionName.azure.example.internal"
$virtualNetworkPrivateDNSlink1  = "link-to-$subscriptionName"
$virtualNetworkPrivateDNSlink2 = "link-to-shared-services"
$virtualNetworkPrivateDNSlink2Id = "<shared-services-vnet-resource-id>"
$virtualNetworkDNSServers = "172.3.4.5"
$virtualNetworkLocation = "westeurope"
$vHubResourceGroupName = "rg-connectivity-vwan"
$vHubName = "hub-westeurope"
$IpamNetworkProd = "10.0.0.0/16"
$IpamNetworkProdCidr = "21"
$IpamNetworkNonProd = "10.10.0.0/16"
$IpamNetworkNonProdCidr = "21"
$IpamServer = "<ipam-server.example.com>"
$IpamApiVersion = "<ipam-api-version>"

# Authenticate using system-assigned managed identity so no local credentials are required.
Connect-AzAccount -Identity -WarningAction Ignore | Out-Null

# For internal subscriptions, reserve the next available subnet in IPAM and persist the allocation.
# External/sandbox subscriptions skip this network reservation flow.
if ($parentmanagementgroup -eq "mg-CorpProduction" -Or $parentmanagementgroup -eq "mg-CorpNonProduction") {
    if ($parentmanagementgroup -eq "mg-CorpProduction") {
        $Network = $IpamNetworkProd
        $Cidr = $IpamNetworkProdCidr
    }
    if ($parentmanagementgroup -eq "mg-CorpNonProduction") {
        $Network = $IpamNetworkNonProd
        $Cidr = $IpamNetworkNonProdCidr
    }

    # This part of the script integrates with an external IPAM system to retrieve and reserve network address space for the new subscription's virtual network.
    # Change this dependly of your IPAM solution
    Set-AzContext -SubscriptionId "<automation-subscription-id>" | Out-Null
    $SecretsVaultName = "<secrets-vault-name>"
    $IPAMUser = Get-AzKeyVaultSecret -VaultName $SecretsVaultName -Name "ipam-user-secret" -AsPlainText
    $IPAMPassword = Get-AzKeyVaultSecret -VaultName $SecretsVaultName -Name "ipam-password-secret" -AsPlainText

    # Convert the secret value to a secure string
    $IPAMPasswordSecure = ConvertTo-SecureString $IPAMPassword -AsPlainText -Force

    $credential = New-Object System.Management.Automation.PSCredential ($IPAMUser, $IPAMPasswordSecure)

    Connect-IPAM -Server $IpamServer -ApiVersion $IpamApiVersion -EnableTLS12 -Credential $credential

    $virtualNetworkAddressSpace = Get-IPAMNetworkNextAvailableNetwork -Network $Network -Cidr $Cidr
    # Guard against duplicate allocation responses by validating the returned network before reserving it.
    $existingNetwork = Get-IPAMNetwork -Network $virtualNetworkAddressSpace
    if ($null -eq $existingNetwork) {
        LogMessage "Address block $virtualNetworkAddressSpace is available and will be registered for $subscriptionName"
        Add-IPAMNetwork -Network $virtualNetworkAddressSpace -Comment $subscriptionName
    } elseif ($null -ne $existingNetwork) {
        LogMessage "Failed to retrieve an available address block for $subscriptionName"
        LogMessage "IPAM duplicate allocation issue encountered. Wait a few minutes and run the script again"
        exit 1  
    }
    Disconnect-IPAM
}

# Summarize the planned changes before any subscription-scoped resource creation starts.
LogMessage "Based on the provided input, the following resources will be created:"
LogMessage "Subscription name = $subscriptionName"
LogMessage "Parent management group = $parentmanagementgroup"
LogMessage "Entra ID group = $azuremgtgroup"
if ($parentmanagementgroup -eq "mg-CorpProduction") {
LogMessage "Entra ID group for PIM = $azuremgtgrouppim (required for production subscriptions)"
}
LogMessage "Subscription workload type = $subscriptiontype"
if ($parentmanagementgroup -eq "mg-Sandbox" -Or $parentmanagementgroup -eq "mg-Other" -Or $parentmanagementgroup -eq "mg-OnlineProduction" -Or $parentmanagementgroup -eq "mg-OnlineNonProduction") {
LogMessage "Azure network vNet and address space are not created for external, other, or sandbox subscriptions"
}
else {
LogMessage "Azure network vNet name = $virtualNetworkName"
LogMessage "Azure network vNet address space = $virtualNetworkAddressSpace"
}

# Create the subscription alias entry and provision the subscription under the configured billing scope.
LogMessage "Creating Azure subscription '$subscriptionName'"
$sub = New-AzSubscriptionAlias -AliasName $subscriptionGuid -SubscriptionName $subscriptionName -BillingScope $subbillingscope -Workload $subscriptiontype

# Function to check if the subscription is created
function CheckSubscription {
    param (
        [string]$subscriptionName
    )
    try {
        $newsubscription = Get-AzSubscription -SubscriptionName $subscriptionName -ErrorAction Stop
        return $null -ne $newsubscription
    }
    catch {
        return $false
    }
}

# Poll subscription availability because alias creation can be eventually consistent.
$subscriptionCreated = $false
$maxAttempts = 30
$delaySeconds = 10

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $subscriptionCreated = CheckSubscription -subscriptionName $subscriptionName
    if ($subscriptionCreated) { break }
    LogMessage "Subscription not yet available, attempt $attempt/$maxAttempts - waiting $delaySeconds seconds..."
    Start-Sleep -Seconds $delaySeconds
}

if (-not $subscriptionCreated) {
    LogMessage "Subscription is not available after $($maxAttempts * $delaySeconds) seconds, stopping script"
    exit 1
}

# Get the newly created subscription id
$subscription = $sub.SubscriptionId
# Select the subscription that is just created 
Select-AzSubscription -SubscriptionId $subscription

# Register the needed resource providers
Register-AzResourceProvider -ProviderNamespace 'Microsoft.Security'
Register-AzResourceProvider -ProviderNamespace 'Microsoft.PolicyInsights'
Register-AzResourceProvider -ProviderNamespace "Microsoft.Maintenance"
Register-AzResourceProvider -ProviderNamespace "Microsoft.DataProtection"

if ($parentmanagementgroup -eq "mg-Sandbox" -Or $parentmanagementgroup -eq "mg-Other" -Or $parentmanagementgroup -eq "mg-OnlineProduction" -Or $parentmanagementgroup -eq "mg-OnlineNonProduction") {
LogMessage "Subscription is external, other, or sandbox; no network environment will be created for this subscription"
}
else {

# Create in the subscription a resource group which holds all the needed network resources with the naming convention rg-network-subscriptionName and the required tags
LogMessage "Creating resource group '$virtualNetworkResourceGroupName' in subscription '$subscriptionName'"
New-AzResourceGroup -Name $virtualNetworkResourceGroupName -Location $virtualNetworkLocation -Tag @{Application="Generic";deploymentType ="Subscription vending"}

# Create in the resource group a virtual network with the supplied virtualNetworkAddressSpace and DNS servers 
LogMessage "Creating virtual network '$virtualNetworkName' in resource group '$virtualNetworkResourceGroupName'"
New-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $virtualNetworkResourceGroupName -Location $virtualNetworkLocation -AddressPrefix $virtualNetworkAddressSpace -DnsServer $virtualNetworkDNSServers

# Create a private DNS zone using the configured suffix (for example subscriptionname.azure.contoso.internal)
LogMessage "Creating Azure private DNS zone '$virtualNetworkPrivateDNSName'"
New-AzPrivateDnsZone -Name $virtualNetworkPrivateDNSName -ResourceGroupName $virtualNetworkResourceGroupName

# Create a Azure private dns zone network link to it's own subnet so that the DNS records are resolvable inside the subscription 
LogMessage "Linking private DNS zone '$virtualNetworkPrivateDNSName' to virtual network '$virtualNetworkName'"
New-AzPrivateDnsVirtualNetworkLink -ZoneName $virtualNetworkPrivateDNSName -ResourceGroupName $virtualNetworkResourceGroupName -Name $virtualNetworkPrivateDNSlink1 -VirtualNetworkId "/subscriptions/$subscription/resourceGroups/$virtualNetworkResourceGroupName/providers/Microsoft.Network/virtualNetworks/$virtualNetworkName" -EnableRegistration

# Create a Azure private dns zone network link to the shared services subscription so that the DNS records are resolvable outside the subscription
LogMessage "Linking private DNS zone '$virtualNetworkPrivateDNSName' to virtual network link '$virtualNetworkPrivateDNSlink2'"
New-AzPrivateDnsVirtualNetworkLink -ZoneName $virtualNetworkPrivateDNSName -ResourceGroupName $virtualNetworkResourceGroupName -Name $virtualNetworkPrivateDNSlink2 -VirtualNetworkId $virtualNetworkPrivateDNSlink2Id

# Get the virtual network information so that the vHub connection can be created 
LogMessage "Retrieving vNet configuration required to create the vHub connection"
$vnet = Get-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $virtualNetworkResourceGroupName

# Now we select the lz-connectivity-wan subscription so that the rest of the virtual network can be build
Select-AzSubscription -SubscriptionId "<connectivity-subscription-id>"

# Create a virtual hub vnet connection so that the subscription is reachable 
LogMessage "Creating vHub vNet connection '$virtualNetworkName' in resource group '$vHubResourceGroupName' and vHub '$vHubName'"
New-AzVirtualHubVnetConnection -ResourceGroupName $vHubResourceGroupName -VirtualHubName $vHubName -Name $virtualNetworkName -RemoteVirtualNetwork $vnet
}

# Move the newly created subscription to its target management group.
LogMessage "Moving subscription '$subscriptionName' to management group '$parentmanagementgroup'"
New-AzManagementGroupSubscription -GroupName $parentmanagementgroup -SubscriptionId $subscription

# First we need logging into MSgraph 
Connect-MgGraph -identity -NoWelcome | Out-Null

# Configure Entra groups and optional PIM flow depending on environment type.
if ($parentmanagementgroup -eq "mg-CorpProduction") {
LogMessage "Creating Entra ID groups including PIM enablement"

# Check if the normal Entra group already exists if it does that group will be used and if not the group will be created
$g01check = Get-MgGroup -Filter "displayName eq '$azuremgtgroup'"
if ($g01check) {
    $g01 = $g01check 
    # The group already exists
    LogMessage "Group '$azuremgtgroup' already exists"
} else {
    # Create the group
    $g01 = New-MgGroup -DisplayName $azuremgtgroup -MailEnabled:$False -MailNickName $azuremgtgroup -SecurityEnabled:$True
    LogMessage "Group '$azuremgtgroup' was created"
}

# Check if the PIM Entra group already exists if it does that group will be used and if not the group will be created
$pg01check = Get-MgGroup -Filter "displayName eq '$azuremgtgrouppim'"
if ($pg01check) {
    $pg01 = $pg01check
    # The group already exists
    LogMessage "Group '$azuremgtgrouppim' already exists"
} else {
    # Create the group
    $pg01 = New-MgGroup -DisplayName $azuremgtgrouppim -MailEnabled:$False -MailNickName $azuremgtgrouppim -SecurityEnabled:$True
    LogMessage "Group '$azuremgtgrouppim' was created"
}

LogMessage "Adding owner(s) to group $azuremgtgroup"
# The blok reads the owners emailadresses which are dived by , and adds them as a owner to the normal Entra group so they can manage this group by adding people to it
$owners = $WhoIsOwner.Split(",")
foreach ($owner in $owners) {
    # Check if the owner account exists
    $ownerExists = Get-MgUser -Filter "mail eq '$owner'"
    if ($ownerExists) {
        # Add owner to the group
        New-MgGroupOwner -GroupId $g01.Id -DirectoryObjectId $ownerExists.id
        LogMessage "Account '$owner' exists and was added as owner to $azuremgtgroup"
    } else {
        LogMessage "Account '$owner' does not exist; validate it and add it manually to $azuremgtgroup later"
    }
}

$azuremgtgroupid = $g01.Id
$azuremgtgroupidpim = $pg01.Id

LogMessage "Applying PIM policies for $azuremgtgrouppim"

    # Helper function for updating policy rules
    function Update-PolicyRule {
        param (
            [string]$GroupId,
            [string]$RuleId,
            [hashtable]$Params
        )
        $policyAssignment = $null
        $attempts = 0
        do {
            try {
                $policyAssignment = Get-MgPolicyRoleManagementPolicyAssignment -Filter $("scopeId eq '{0}' and scopeType eq 'Group' and RoleDefinitionId eq 'member'" -f $GroupId) -ErrorAction SilentlyContinue
            } catch {
                Start-Sleep -Seconds 2
            }
            $attempts++
        } while (-not $policyAssignment -and $attempts -lt 3)

        if ($policyAssignment) {
               Update-MgPolicyRoleManagementPolicyRule -UnifiedRoleManagementPolicyId $policyAssignment.PolicyId -UnifiedRoleManagementPolicyRuleId $RuleId -BodyParameter $Params
            }
    }

    # 1. Expiration Rule
    $params1 = @{
        "@odata.type" = "#microsoft.graph.unifiedRoleManagementPolicyExpirationRule"
        id = "Expiration_Admin_Eligibility"
        isExpirationRequired = $false
        target = @{
            "@odata.type" = "microsoft.graph.unifiedRoleManagementPolicyRuleTarget"
            caller = "Admin"
            operations = @("All")
            level = "Eligibility"
            inheritableSettings = @()
            enforcedSettings = @()
        }
    }
    Update-PolicyRule -GroupId $pg01.Id -RuleId "Expiration_Admin_Eligibility" -Params $params1

    # 2. Approval Rule
    $params2 = @{
        "@odata.type" = "#microsoft.graph.unifiedRoleManagementPolicyApprovalRule"
        id = "Approval_EndUser_Assignment"
        target = @{
            "@odata.type" = "microsoft.graph.unifiedRoleManagementPolicyRuleTarget"
            caller = "EndUser"
            operations = @("All")
            level = "Assignment"
            inheritableSettings = @()
            enforcedSettings = @()
        }
        setting = @{
            "@odata.type" = "microsoft.graph.approvalSettings"
            isApprovalRequired = $true
            isApprovalRequiredForExtension = $false
            isRequestorJustificationRequired = $true
            approvalMode = "SingleStage"
            approvalStages = @(
                @{
                    "@odata.type" = "microsoft.graph.unifiedApprovalStage"
                    approvalStageTimeOutInDays = "1"
                    isApproverJustificationRequired = $true
                    escalationTimeInMinutes = "0"
                    primaryApprovers = @(
                        @{
                            "@odata.type" = "#microsoft.graph.groupMembers"
                            groupId = "$($g01.Id)"
                        }
                    )
                    isEscalationEnabled = $false
                    escalationApprovers = @()
                }
            )
        }
    }
    Update-PolicyRule -GroupId $pg01.Id -RuleId "Approval_EndUser_Assignment" -Params $params2

    # 3. Enablement Rule
    $params3 = @{
        "@odata.type" = "#microsoft.graph.unifiedRoleManagementPolicyEnablementRule"
        id = "Enablement_EndUser_Assignment"
        enabledRules = @("Justification", "MultiFactorAuthentication")
        target = @{
            "@odata.type" = "microsoft.graph.unifiedRoleManagementPolicyRuleTarget"
            caller = "EndUser"
            operations = @("All")
            level = "Assignment"
            inheritableSettings = @()
            enforcedSettings = @()
        }
    }
    Update-PolicyRule -GroupId $pg01.Id -RuleId "Enablement_EndUser_Assignment" -Params $params3

    # 4. Notification Rule
    $params4 = @{
        "@odata.type" = "#microsoft.graph.unifiedRoleManagementPolicyNotificationRule"
        id = "Notification_Admin_EndUser_Assignment"
        notificationType = "Email"
        recipientType = "Admin"
        isDefaultRecipientsEnabled = $true
        notificationLevel = "All"
        notificationRecipients = @("security@example.com")
        target = @{
            "@odata.type" = "microsoft.graph.unifiedRoleManagementPolicyRuleTarget"
            caller = "EndUser"
            operations = @("All")
            level = "Assignment"
            targetObjects = @()
            inheritableSettings = @()
            enforcedSettings = @()
        }
    }
    Update-PolicyRule -GroupId $pg01.Id -RuleId "Notification_Admin_EndUser_Assignment" -Params $params4

    LogMessage "Adding group '$azuremgtgroup' as member of PIM group '$azuremgtgrouppim' (this step can take some time)"
    # A short wait so that all policies can be settled in
    Start-Sleep -Seconds 10
    
    # 5. Add group as member of PIM group
    $params5 = @{
        accessId = "member"
        principalId = "$($g01.Id)"
        groupId = "$($pg01.Id)"
        action = "AdminAssign"
        scheduleInfo = @{
            startDateTime = (Get-Date)
            expiration = @{
                type = "noExpiration"
            }
        }
        justification = "Added new created group $($g01.DisplayName) as a member of the PIM group $($pg01.DisplayName)"
    }
    New-MgIdentityGovernancePrivilegedAccessGroupEligibilityScheduleRequest -BodyParameter $params5

}
else {
LogMessage "Creating standard Entra ID group without PIM enablement"

# Check if the normal Entra group already exists if it does that group will be used and if not the group will be created
$g01check = Get-MgGroup -Filter "displayName eq '$azuremgtgroup'"
if ($g01check) {
    $g01 = $g01check 
    # The group already exists
    LogMessage "Group '$azuremgtgroup' already exists"
} else {
    # Create the group
    $g01 = New-MgGroup -DisplayName $azuremgtgroup -MailEnabled:$False -MailNickName $azuremgtgroup -SecurityEnabled:$True
    LogMessage "Group '$azuremgtgroup' was created"
}

LogMessage "Adding owner(s) to group $azuremgtgroup"
# The blok reads the owners emailadresses which are dived by , and adds them as a owner to the normal Entra group so they can manage this group by adding people to it
$owners = $WhoIsOwner.Split(",")
foreach ($owner in $owners) {
    # Check if the owner account exists
    $ownerExists = Get-MgUser -Filter "mail eq '$owner'"
    if ($ownerExists) {
        # Add owner to the group
        New-MgGroupOwner -GroupId $g01.Id -DirectoryObjectId $ownerExists.id
        LogMessage "Account '$owner' exists and was added as owner to $azuremgtgroup"
    } else {
        LogMessage "Account '$owner' does not exist; validate it and add it manually to $azuremgtgroup later"
    }
}
$azuremgtgroupid = $g01.Id
}

# Compose and send a post-provisioning email with key details and RBAC code snippets.
# This provides operators a ready-to-copy artifact for landing zone role assignments.
# Email details
$fromAddress = 'noreply@example.com'
$toAddress = 'cloud-ops@example.com'
$type = "HTML" 
$save = "false" 

# Specify the email subject and build the message body.
$mailSubject = "Azure subscription created for $subscriptionName"
$mailMessage = "Based on the information entered in Azure Automation Create Azure subscription, the following resources were created in Azure:<p>"
$mailMessage += "Subscription name = $subscriptionName<br>"
$mailMessage += "Parent management group = $parentmanagementgroup<br>"
$mailMessage += "Azure AD group = $azuremgtgroup<br>"
$mailMessage += "Workload type = $subscriptiontype<p>"
if ($parentmanagementgroup -eq "mg-Sandbox" -Or $parentmanagementgroup -eq "mg-Other" -Or $parentmanagementgroup -eq "mg-OnlineProduction" -Or $parentmanagementgroup -eq "mg-OnlineNonProduction") {
$mailMessage += "Azure network vNet name and address space are not created for external, other, or sandbox subscriptions<p>"}
else {
$mailMessage += "Azure network vNet name = $virtualNetworkName<br>"
$mailMessage += "Azure network vNet address space = $virtualNetworkAddressSpace<p>"
}
$mailMessage += "A code block has also been generated for use in Bicep to configure group permissions correctly. For more information, see <internal-doc-url><p>"
$mailMessage += "The Bicep code below can be added to the `iam_sub = []` section of `lz.bicep` in <rbac-repository-url><p>"
$mailMessage += $pre+ "// $subscriptionName"
$mailMessage += $pre+ "{"
$mailMessage += $pre+ "  subscriptionid: '$subscription' // $subscriptionName"
if ($parentmanagementgroup -eq "mg-CorpProduction") {
$mailMessage += $pre+ "  principalid: '$azuremgtgroupidpim' // $azuremgtgrouppim"
}
else {
$mailMessage += $pre+ "  principalid: '$azuremgtgroupid' // $azuremgtgroup"
}
$mailMessage += $pre+ "  roleDefinition: 'Subscription Operator'"
$mailMessage += $pre+ "}"
if ($parentmanagementgroup -eq "mg-CorpProduction") {
$mailMessage += $pre+ "{"
$mailMessage += $pre+ "  subscriptionid: '$subscription' // $subscriptionName"
$mailMessage += $pre+ "  principalid: '$azuremgtgroupid' // $azuremgtgroup"
$mailMessage += $pre+ "  roleDefinition: 'Reader'"
$mailMessage += $pre+ "}"
}

$mailparams = @{
    Message         = @{
        Subject       = $mailSubject
        Body          = @{
            ContentType = $type
            Content     = $mailMessage
        }
        ToRecipients  = @(
            @{
                EmailAddress = @{
                    Address = $toAddress
                }
            }
        )
    }
    SaveToSentItems = $save
}
# Send message
Send-MgUserMail -UserId $fromAddress -BodyParameter $mailparams
LogMessage "Email was sent to '$toAddress' with all subscription details, including the Bicep code block"
LogMessage "Subscription has been created; check the operations mailbox for next steps"
LogMessage "Starting activation and validation of post-provisioning resources"

# Enabling the most important Defender for Cloud plans
LogMessage "Enabling Defender for Cloud plans"

# Select the subscription that is just created 
Select-AzSubscription -SubscriptionId $subscription

Set-AzSecurityPricing -Name "VirtualMachines" -PricingTier "Standard" 
Set-AzSecurityPricing -Name "SqlServers" -PricingTier "Standard"
Set-AzSecurityPricing -Name "AppServices" -PricingTier "Standard"
Set-AzSecurityPricing -Name "StorageAccounts" -PricingTier "Standard" -SubPlan "DefenderForStorageV2"
Set-AzSecurityPricing -Name "SqlServerVirtualMachines" -PricingTier "Standard"
Set-AzSecurityPricing -Name "KeyVaults" -PricingTier "Standard"
Set-AzSecurityPricing -Name "OpenSourceRelationalDatabases" -PricingTier "Standard"
Set-AzSecurityPricing -Name "Containers" -PricingTier "Standard"
Set-AzSecurityPricing -Name "CosmosDbs" -PricingTier "Standard"
Set-AzSecurityPricing -Name "CloudPosture" -PricingTier "Standard"
Set-AzSecurityPricing -Name "Arm" -PricingTier "Standard"

if ($parentmanagementgroup -eq "mg-CorpProduction") {
LogMessage "Reapplying and validating PIM policies for $azuremgtgrouppim"
Update-PolicyRule -GroupId $pg01.Id -RuleId "Expiration_Admin_Eligibility" -Params $params1
Update-PolicyRule -GroupId $pg01.Id -RuleId "Approval_EndUser_Assignment" -Params $params2
Update-PolicyRule -GroupId $pg01.Id -RuleId "Enablement_EndUser_Assignment" -Params $params3
Update-PolicyRule -GroupId $pg01.Id -RuleId "Notification_Admin_EndUser_Assignment" -Params $params4
}

LogMessage "Script completed successfully"