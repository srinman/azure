#!/bin/bash
# Automated deployment script for VM to Function App with Managed Identity

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}VM to Function App Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo

# Set variables
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-vm-function-demo}"
LOCATION="${LOCATION:-eastus}"
VM_NAME="${VM_NAME:-vm-ubuntu-demo}"
VM_SIZE="${VM_SIZE:-Standard_D2s_v3}"
MANAGED_IDENTITY_NAME="${MANAGED_IDENTITY_NAME:-id-vm-to-function}"
FUNC_STORAGE_IDENTITY_NAME="${FUNC_STORAGE_IDENTITY_NAME:-func-host-storage-user}"
FUNCTION_APP_NAME="${FUNCTION_APP_NAME:-func-secure-demo-$(date +%s)}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-stfunc$(date +%s | tail -c 8)}"
VNET_NAME="${VNET_NAME:-vnet-demo}"
SUBNET_NAME="${SUBNET_NAME:-subnet-vm}"
NSG_NAME="${NSG_NAME:-nsg-vm}"

echo -e "${YELLOW}Configuration:${NC}"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Location: $LOCATION"
echo "  VM Name: $VM_NAME"
echo "  VM Size: $VM_SIZE"
echo "  Managed Identity: $MANAGED_IDENTITY_NAME"
echo "  Function App: $FUNCTION_APP_NAME"
echo "  Storage Account: $STORAGE_ACCOUNT_NAME"
echo

read -p "Continue with deployment? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

# Step 1: Create Resource Group
echo -e "\n${BLUE}Step 1: Creating Resource Group...${NC}"
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION \
  --output none
echo -e "${GREEN}✅ Resource group created${NC}"

# Step 2: Create Managed Identity
echo -e "\n${BLUE}Step 2: Creating User-Assigned Managed Identity...${NC}"
az identity create \
  --name $MANAGED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --output none

IDENTITY_ID=$(az identity show \
  --name $MANAGED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

IDENTITY_CLIENT_ID=$(az identity show \
  --name $MANAGED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query clientId -o tsv)

IDENTITY_PRINCIPAL_ID=$(az identity show \
  --name $MANAGED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query principalId -o tsv)

echo -e "${GREEN}✅ Managed Identity created${NC}"
echo "   Client ID: $IDENTITY_CLIENT_ID"
echo "   Principal ID: $IDENTITY_PRINCIPAL_ID"

# Step 3: Create Virtual Network
echo -e "\n${BLUE}Step 3: Creating Virtual Network...${NC}"
az network vnet create \
  --name $VNET_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --address-prefix 10.0.0.0/16 \
  --subnet-name $SUBNET_NAME \
  --subnet-prefix 10.0.1.0/24 \
  --output none

# Create NSG
az network nsg create \
  --name $NSG_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --output none

# Allow SSH
az network nsg rule create \
  --name AllowSSH \
  --nsg-name $NSG_NAME \
  --resource-group $RESOURCE_GROUP \
  --priority 1000 \
  --source-address-prefixes '*' \
  --destination-port-ranges 22 \
  --protocol Tcp \
  --access Allow \
  --output none

# Allow HTTPS outbound
az network nsg rule create \
  --name AllowHTTPS \
  --nsg-name $NSG_NAME \
  --resource-group $RESOURCE_GROUP \
  --priority 1001 \
  --direction Outbound \
  --source-address-prefixes '*' \
  --destination-port-ranges 443 \
  --protocol Tcp \
  --access Allow \
  --output none

# Associate NSG with subnet
az network vnet subnet update \
  --name $SUBNET_NAME \
  --vnet-name $VNET_NAME \
  --resource-group $RESOURCE_GROUP \
  --network-security-group $NSG_NAME \
  --output none

echo -e "${GREEN}✅ Virtual network and NSG created${NC}"

# Step 4: Create VM
echo -e "\n${BLUE}Step 4: Creating Ubuntu VM...${NC}"
az vm create \
  --name $VM_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --image Ubuntu2204 \
  --size $VM_SIZE \
  --admin-username azureuser \
  --generate-ssh-keys \
  --vnet-name $VNET_NAME \
  --subnet $SUBNET_NAME \
  --nsg $NSG_NAME \
  --assign-identity $IDENTITY_ID \
  --public-ip-sku Standard \
  --output none

VM_PUBLIC_IP=$(az vm show \
  --name $VM_NAME \
  --resource-group $RESOURCE_GROUP \
  --show-details \
  --query publicIps -o tsv)

echo -e "${GREEN}✅ VM created${NC}"
echo "   Public IP: $VM_PUBLIC_IP"
echo "   SSH: ssh azureuser@$VM_PUBLIC_IP"

# Step 5: Create Storage Account (without shared key access)
echo -e "\n${BLUE}Step 5: Creating Storage Account (secure mode - no storage keys)...${NC}"
az storage account create \
  --name $STORAGE_ACCOUNT_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --output none
echo -e "${GREEN}✅ Storage account created (no shared key access)${NC}"

# Step 6: Create Function Storage Managed Identity
echo -e "\n${BLUE}Step 6: Creating Function Storage Managed Identity...${NC}"
az identity create \
  --name $FUNC_STORAGE_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --output none

# Get identity details
output=$(az identity show \
  --name $FUNC_STORAGE_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query "{userId:id, principalId: principalId, clientId: clientId}" -o json)

FUNC_STORAGE_USER_ID=$(echo $output | jq -r '.userId')
FUNC_STORAGE_PRINCIPAL_ID=$(echo $output | jq -r '.principalId')
FUNC_STORAGE_CLIENT_ID=$(echo $output | jq -r '.clientId')

echo -e "${GREEN}✅ Function Storage Identity created${NC}"
echo "   Client ID: $FUNC_STORAGE_CLIENT_ID"

# Assign Storage Blob Data Owner role
STORAGE_ID=$(az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT_NAME \
  --query 'id' -o tsv)

az role assignment create \
  --assignee-object-id $FUNC_STORAGE_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Owner" \
  --scope $STORAGE_ID \
  --output none

echo -e "${GREEN}✅ Storage role assigned${NC}"

# Step 7: Create Function App with Managed Identity
echo -e "\n${BLUE}Step 7: Creating Function App with Managed Identity for storage...${NC}"
az functionapp create \
  --resource-group $RESOURCE_GROUP \
  --flexconsumption-location $LOCATION \
  --runtime python \
  --runtime-version 3.11 \
  --storage-account $STORAGE_ACCOUNT_NAME \
  --name $FUNCTION_APP_NAME \
  --deployment-storage-auth-type UserAssignedIdentity \
  --deployment-storage-auth-value $FUNC_STORAGE_IDENTITY_NAME \
  --output none

FUNCTION_APP_URL="https://${FUNCTION_APP_NAME}.azurewebsites.net"
echo -e "${GREEN}✅ Function App created${NC}"
echo "   URL: $FUNCTION_APP_URL"

# Configure storage settings
az functionapp config appsettings set \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --settings AzureWebJobsStorage__accountName=$STORAGE_ACCOUNT_NAME \
  AzureWebJobsStorage__credential=managedidentity \
  AzureWebJobsStorage__clientId=$FUNC_STORAGE_CLIENT_ID \
  --output none

# Remove connection string setting
az functionapp config appsettings delete \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --setting-names AzureWebJobsStorage 2>/dev/null || true

echo -e "${GREEN}✅ Function App configured with managed identity for storage${NC}"

# Step 8: Configure Authentication
echo -e "\n${BLUE}Step 8: Configuring Authentication with App Registration...${NC}"

# Get tenant ID
TENANT_ID=$(az account show --query tenantId -o tsv)

# Create Azure AD App Registration
echo "Creating App Registration..."
APP_REG_NAME="${FUNCTION_APP_NAME}-app"
APP_ID=$(az ad app create \
  --display-name $APP_REG_NAME \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)

echo -e "${GREEN}✅ App Registration created${NC}"
echo "   App ID: $APP_ID"

# Set Application ID URI (required for managed identity token requests)
echo "Setting Application ID URI..."
az ad app update --id $APP_ID --identifier-uris "api://${APP_ID}"
echo -e "${GREEN}✅ Application ID URI set: api://${APP_ID}${NC}"

# Create Service Principal
SP_ID=$(az ad sp create --id $APP_ID --query id -o tsv)
echo -e "${GREEN}✅ Service Principal created${NC}"

# Configure Easy Auth with App Registration
az webapp auth update \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --enabled true \
  --action LoginWithAzureActiveDirectory \
  --aad-client-id $APP_ID \
  --aad-token-issuer-url "https://sts.windows.net/${TENANT_ID}/" \
  --aad-allowed-token-audiences "api://${APP_ID}" \
  --output none

# Set allowed client ID for function code validation
az functionapp config appsettings set \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --settings ALLOWED_CLIENT_ID=$IDENTITY_CLIENT_ID \
  --output none

echo -e "${GREEN}✅ Authentication configured${NC}"
echo "   App ID: $APP_ID"
echo "   Token Audience: api://${APP_ID}"
echo "   VM Managed Identity Client ID: $IDENTITY_CLIENT_ID"

# Step 9: Authentication configuration complete
echo -e "\n${BLUE}Step 9: Authentication configuration complete${NC}"
echo "Note: Using App Registration + code-based validation with client ID checks"

# Summary
echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Deploy your function code:"
echo "   cd function-app-code"
echo "   func azure functionapp publish $FUNCTION_APP_NAME"
echo
echo "2. SSH into the VM and test:"
echo "   ssh azureuser@$VM_PUBLIC_IP"
echo
echo "3. On the VM, run the test script with App ID:"
echo "   ./call-function.sh \"$FUNCTION_APP_URL\" \"$APP_ID\""
echo
echo -e "${YELLOW}Resource Details:${NC}"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  VM Public IP: $VM_PUBLIC_IP"
echo "  Function App URL: $FUNCTION_APP_URL"
echo "  App Registration ID: $APP_ID"
echo "  VM Managed Identity Client ID: $IDENTITY_CLIENT_ID"
echo
echo "To clean up: az group delete --name $RESOURCE_GROUP --yes"
echo