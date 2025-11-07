1#!/bin/bash

# Deploy to Azure Container Apps
# Deploys both API and Web App to Azure Container Apps

set -e

echo "========================================"
echo "Deploy to Azure Container Apps"
echo "========================================"
echo ""

# Configuration - customize these
RESOURCE_GROUP="rg-webapp-calls-api"
LOCATION="eastus2"
ENVIRONMENT_NAME="srinman-acaenv"
ACR_NAME="acrwebappcallsapi$(date +%s)"  # Must be globally unique
ACR_NAME=srinmantest
API_APP_NAME="api-app"
WEB_APP_NAME="web-app"

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
# Step 2: Create Azure Container Registry
# ============================================
echo "Step 2: Creating Azure Container Registry..."
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
# Step 3: Build and Push API Image
# ============================================
echo "Step 3: Building and pushing API image..."
az acr build \
    --registry $ACR_NAME \
    --image $API_APP_NAME:latest \
    --file api/Dockerfile \
    api/

echo "✓ API image built and pushed"
echo ""

# To update an existing API container app with the latest image:
# az containerapp update \
#   --name api-app \
#   --resource-group rg-webapp-calls-api \
#   --image srinmantest.azurecr.io/api-app:latest

# ============================================
# Step 4: Build and Push Web App Image
# ============================================
echo "Step 4: Building and pushing Web App image..."
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
#   --resource-group rg-webapp-calls-api \
#   --image srinmantest.azurecr.io/web-app:latest

# ============================================
# Step 5: Create Container Apps Environment
# ============================================
echo "Step 5: Creating Container Apps environment..."
az containerapp env create \
    --name $ENVIRONMENT_NAME \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION \
    --output none

echo "✓ Container Apps environment created"
echo ""

# ============================================
# Step 6: Deploy API Container App
# ============================================
echo "Step 6: Deploying API Container App..."
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
# Step 7: Update Web App Redirect URI
# ============================================
echo "Step 7: Updating redirect URI in Entra ID..."

WEB_APP_FQDN_TEMP="temp-update-later"  # Will be updated after web app is created

echo "⚠ Redirect URI will be updated after web app deployment"
echo ""

# ============================================
# Step 8: Deploy Web App Container App
# ============================================
echo "Step 8: Deploying Web App Container App..."
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
    --env-vars \
        "CLIENT_ID=$CLIENT_ID" \
        "CLIENT_SECRET=$CLIENT_SECRET" \
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
# Step 9: Update Entra ID Redirect URI
# ============================================
echo "Step 9: Updating Entra ID redirect URI..."

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
echo "API Application:"
echo "  URL: https://$API_FQDN"
echo "  Health Check: https://$API_FQDN/health"
echo "  Claims Endpoint: https://$API_FQDN/api/claims"
echo ""
echo "Web Application:"
echo "  URL: https://$WEB_APP_FQDN"
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
echo "To restart apps (if needed):"
echo "  # Stop and start API:"
echo "  az containerapp revision deactivate --name $API_APP_NAME --resource-group $RESOURCE_GROUP --revision \$(az containerapp revision list --name $API_APP_NAME --resource-group $RESOURCE_GROUP --query '[0].name' -o tsv)"
echo "  az containerapp revision activate --name $API_APP_NAME --resource-group $RESOURCE_GROUP --revision \$(az containerapp revision list --name $API_APP_NAME --resource-group $RESOURCE_GROUP --query '[0].name' -o tsv)"
echo ""
echo "  # Stop and start Web App:"
echo "  az containerapp revision deactivate --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP --revision \$(az containerapp revision list --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP --query '[0].name' -o tsv)"
echo "  az containerapp revision activate --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP --revision \$(az containerapp revision list --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP --query '[0].name' -o tsv)"
echo ""
echo "To delete all resources:"
echo "  az group delete --name $RESOURCE_GROUP --yes"
echo ""
