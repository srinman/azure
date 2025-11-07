1#!/bin/bash

# Deploy to Azure Container Apps with Managed Identity
# Uses User-Assigned Managed Identity with Federated Credentials (no client secret)

set -e

echo "========================================"
echo "Deploy to Azure Container Apps"
echo "Using Managed Identity + Federated Credentials"
echo "========================================"
echo ""

# Configuration - customize these
RESOURCE_GROUP="rg-webapp-calls-api"
LOCATION="eastus2"
ENVIRONMENT_NAME="srinman-acaenv"
ACR_NAME="srinmantest"
API_APP_NAME="api-app"
WEB_APP_NAME="web-app"
MANAGED_IDENTITY_NAME="mi-webapp-federated"

# Check if environment variables are set
if [ -z "$CLIENT_ID" ] || [ -z "$API_CLIENT_ID" ] || [ -z "$TENANT_ID" ]; then
    echo "Error: Environment variables not set"
    echo "Please run: source ./setup-entraid.sh first"
    exit 1
fi

echo "Using configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Location: $LOCATION"
echo "  Container Registry: $ACR_NAME"
echo "  Managed Identity: $MANAGED_IDENTITY_NAME"
echo ""

# ============================================
# Step 1: Create Resource Group
# ============================================
echo "Step 1: Creating resource group..."
az group create \
    --name $RESOURCE_GROUP \
    --location $LOCATION \
    --output none

echo "✓ Resource group created"
echo ""

# ============================================
# Step 2: Create User-Assigned Managed Identity
# ============================================
echo "Step 2: Creating User-Assigned Managed Identity..."
az identity create \
    --name $MANAGED_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION \
    --output none

# Get managed identity details
MANAGED_IDENTITY_ID=$(az identity show \
    --name $MANAGED_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --query id -o tsv)

MANAGED_IDENTITY_CLIENT_ID=$(az identity show \
    --name $MANAGED_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --query clientId -o tsv)

MANAGED_IDENTITY_PRINCIPAL_ID=$(az identity show \
    --name $MANAGED_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --query principalId -o tsv)

echo "✓ Managed Identity created"
echo "  Client ID: $MANAGED_IDENTITY_CLIENT_ID"
echo "  Principal ID: $MANAGED_IDENTITY_PRINCIPAL_ID"
echo ""

# ============================================
# Step 3: Create Azure Container Registry
# ============================================
echo "Step 3: Creating Azure Container Registry..."
az acr create \
    --resource-group $RESOURCE_GROUP \
    --name $ACR_NAME \
    --sku Basic \
    --admin-enabled true \
    --output none

echo "✓ Container Registry created"

# Get ACR credentials
ACR_SERVER=$(az acr show --name $ACR_NAME --query loginServer -o tsv)
ACR_USERNAME=$(az acr credential show --name $ACR_NAME --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name $ACR_NAME --query passwords[0].value -o tsv)

echo "  Server: $ACR_SERVER"
echo ""

# ============================================
# Step 4: Build and Push API Image
# ============================================
echo "Step 4: Building and pushing API image..."
az acr build \
    --registry $ACR_NAME \
    --image $API_APP_NAME:latest \
    --file api/Dockerfile \
    api/

echo "✓ API image built and pushed"
echo ""

# ============================================
# Step 5: Build and Push Web App Image
# ============================================
echo "Step 5: Building and pushing Web App image..."
az acr build \
    --registry $ACR_NAME \
    --image $WEB_APP_NAME:latest \
    --file web-app/Dockerfile \
    web-app/

echo "✓ Web App image built and pushed"
echo ""

# To update an existing Web App container app with the latest image:
# az containerapp update \
#   --name web-app \
echo ""

# ============================================
# Step 6: Create Container Apps Environment
# ============================================
echo "Step 6: Creating Container Apps environment..."
az containerapp env create \
    --name $ENVIRONMENT_NAME \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION \
    --output none

echo "✓ Container Apps environment created"
echo ""

# ============================================
# Step 7: Deploy API Container App
# ============================================
echo "Step 7: Deploying API Container App..."
az containerapp create \
    --name $API_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --environment $ENVIRONMENT_NAME \
    --image "$ACR_SERVER/$API_APP_NAME:latest" \
    --target-port 5001 \
    --ingress external \
    --registry-server $ACR_SERVER \
    --registry-username $ACR_USERNAME \
    --registry-password $ACR_PASSWORD \
    --env-vars \
        "TENANT_ID=$TENANT_ID" \
        "API_CLIENT_ID=$API_CLIENT_ID" \
        "PORT=5001" \
    --cpu 0.25 \
    --memory 0.5Gi \
    --min-replicas 1 \
    --max-replicas 1 \
    --output none

API_FQDN=$(az containerapp show \
    --name $API_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --query properties.configuration.ingress.fqdn -o tsv)

API_URL="https://$API_FQDN/api/claims"

echo "✓ API deployed"
echo "  URL: https://$API_FQDN"
echo ""

# ============================================
# Step 8: Deploy Web App Container App with Managed Identity
# ============================================
echo "Step 8: Deploying Web App Container App with Managed Identity..."
az containerapp create \
    --name $WEB_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --environment $ENVIRONMENT_NAME \
    --image "$ACR_SERVER/$WEB_APP_NAME:latest" \
    --target-port 5000 \
    --ingress external \
    --registry-server $ACR_SERVER \
    --registry-username $ACR_USERNAME \
    --registry-password $ACR_PASSWORD \
    --user-assigned $MANAGED_IDENTITY_ID \
    --env-vars \
        "CLIENT_ID=$CLIENT_ID" \
        "MANAGED_IDENTITY_CLIENT_ID=$MANAGED_IDENTITY_CLIENT_ID" \
        "TENANT_ID=$TENANT_ID" \
        "API_CLIENT_ID=$API_CLIENT_ID" \
        "API_ENDPOINT=$API_URL" \
        "PORT=5000" \
    --cpu 0.25 \
    --memory 0.5Gi \
    --min-replicas 1 \
    --max-replicas 1 \
    --output none

WEB_APP_FQDN=$(az containerapp show \
    --name $WEB_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --query properties.configuration.ingress.fqdn -o tsv)

echo "✓ Web App deployed"
echo "  URL: https://$WEB_APP_FQDN"
echo ""

# ============================================
# Step 9: Configure Federated Credential (Manual Step)
# ============================================
echo "========================================"
echo "⚠ MANUAL STEP REQUIRED"
echo "========================================"
echo ""
echo "Step 9: Configure federated credential via Azure Portal"
echo ""
echo "You need to add a federated credential to allow the managed identity"
echo "to authenticate on behalf of the web app registration."
echo ""
echo "Instructions:"
echo "  1. Go to Azure Portal: https://portal.azure.com"
echo "  2. Navigate to: Entra ID > App registrations"
echo "  3. Find and open: 'Web App Calls API Demo' (Client ID: $CLIENT_ID)"
echo "  4. Go to: Certificates & secrets > Federated credentials"
echo "  5. Click: Add credential"
echo "  6. Select scenario: 'Managed Identity'"
echo "  7. Fill in the following:"
echo "     - Subscription: <your subscription>"
echo "     - Managed identity: mi-webapp-federated"
echo "     - Name: fedcred-webapp-mi"
echo "     - Description: Federated credential for user-assigned managed identity"
echo "  8. Click: Add"
echo ""
echo "Managed Identity Details:"
echo "  Name: $MANAGED_IDENTITY_NAME"
echo "  Client ID: $MANAGED_IDENTITY_CLIENT_ID"
echo "  Resource Group: $RESOURCE_GROUP"
echo ""
read -p "Press Enter after you have completed this step in the portal..."
echo ""
echo "✓ Federated credential configuration confirmed"
echo ""

# ============================================
# Step 10: Update Entra ID Redirect URI
# ============================================
echo "Step 10: Updating Entra ID redirect URI..."

az ad app update \
    --id $CLIENT_ID \
    --web-redirect-uris "http://localhost:5000/getAToken" "https://$WEB_APP_FQDN/getAToken"

echo "✓ Redirect URI updated to include: https://$WEB_APP_FQDN/getAToken"
echo ""

# ============================================
# Deployment Complete
# ============================================
echo "========================================"
echo "Deployment Complete!"
echo "========================================"
echo ""
echo "Authentication Configuration:"
echo "  Managed Identity: $MANAGED_IDENTITY_NAME"
echo "  Managed Identity Client ID: $MANAGED_IDENTITY_CLIENT_ID"
echo "  Federated Credential: $FEDERATED_CRED_NAME"
echo "  Web App Registration: $CLIENT_ID"
echo ""
echo "API Application:"
echo "  URL: https://$API_FQDN"
echo "  Health Check: https://$API_FQDN/health"
echo "  Claims Endpoint: https://$API_FQDN/api/claims"
echo ""
echo "Web Application:"
echo "  URL: https://$WEB_APP_FQDN"
echo ""
echo "How it works:"
echo "  1. Web App uses User-Assigned Managed Identity (no secrets!)"
echo "  2. Managed Identity has federated credential with Web App registration"
echo "  3. Azure AD trusts the managed identity to acquire tokens for the app"
echo "  4. This eliminates the need for client secrets in your application"
echo ""
echo "To test:"
echo "  1. Open https://$WEB_APP_FQDN"
echo "  2. Click 'Sign In'"
echo "  3. Authenticate with your account"
echo "  4. Click 'Call Protected API'"
echo "  5. View the token claims returned from the API"
echo ""
echo "To view logs:"
echo "  az containerapp logs show --name $API_APP_NAME --resource-group $RESOURCE_GROUP --follow"
echo "  az containerapp logs show --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP --follow"
echo ""
echo "To update apps with latest code changes:"
echo "  # Rebuild and update API:"
echo "  az acr build --registry $ACR_NAME --image $API_APP_NAME:latest --file api/Dockerfile api/"
echo "  az containerapp update --name $API_APP_NAME --resource-group $RESOURCE_GROUP --image $ACR_SERVER/$API_APP_NAME:latest"
echo ""
echo "  # Rebuild and update Web App:"
echo "  az acr build --registry $ACR_NAME --image $WEB_APP_NAME:latest --file web-app/Dockerfile web-app/"
echo "  az containerapp update --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP --image $ACR_SERVER/$WEB_APP_NAME:latest"
echo ""
echo "To delete all resources:"
echo "  # Delete Azure resources:"
echo "  az group delete --name $RESOURCE_GROUP --yes"
echo ""
echo "  # Delete Entra ID objects:"
echo "  az ad app delete --id $CLIENT_ID"
echo "  az ad app delete --id $API_CLIENT_ID"
echo ""
