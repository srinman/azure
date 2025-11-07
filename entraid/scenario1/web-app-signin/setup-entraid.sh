#!/bin/bash

# Web App Sign-In with Entra ID - Setup Script
# This script creates all necessary Entra ID resources using Azure CLI

set -e

echo "========================================"
echo "Entra ID Web App Sign-In Setup"
echo "========================================"

# Variables - Customize these
APP_NAME="webapp-signin-demo"
REDIRECT_URI="http://localhost:5000/getAToken"
LOGOUT_URI="http://localhost:5000"

echo ""
echo "Creating app registration: $APP_NAME"
echo "========================================"

# Create app registration
# For web apps that sign in users, we use the 'web' platform with authorization code flow
APP_ID=$(az ad app create \
    --display-name "$APP_NAME" \
    --sign-in-audience "AzureADMyOrg" \
    --web-redirect-uris "$REDIRECT_URI" \
    --enable-id-token-issuance true \
    --query appId -o tsv)

echo "App Registration created successfully!"
echo "Application (client) ID: $APP_ID"

# Get tenant ID
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "Tenant ID: $TENANT_ID"

# Create a client secret
echo ""
echo "Creating client secret..."
CLIENT_SECRET=$(az ad app credential reset \
    --id $APP_ID \
    --append \
    --query password -o tsv)

echo "Client secret created successfully!"

echo ""
echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo ""
echo "IMPORTANT: Setting environment variables in this session"
echo ""

# Export the credentials as environment variables
export CLIENT_ID="$APP_ID"
export CLIENT_SECRET="$CLIENT_SECRET"
export TENANT_ID="$TENANT_ID"

echo "✓ CLIENT_ID exported"
echo "✓ CLIENT_SECRET exported"
echo "✓ TENANT_ID exported"
echo ""
echo "========================================"
echo "Credentials are now set for this terminal session"
echo "========================================"
echo ""
echo "To use in this session:"
echo "  source ./setup-entraid.sh    (must use 'source' to export vars)"
echo "  python3 app.py"
echo ""
echo "Or use the convenience script:"
echo "  ./run-app.sh"
echo ""
