#!/bin/bash

# Setup Script for Scenario 2: Web App Calls API
# Creates two app registrations:
# 1. API app (protected resource)
# 2. Web app (client that calls the API)

set -e

echo "========================================"
echo "Scenario 2: Web App Calls API Setup"
echo "========================================"
echo ""

# Get tenant ID
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "Tenant ID: $TENANT_ID"
echo ""

# ============================================
# Step 1: Create API App Registration
# ============================================
echo "Step 1: Creating API app registration..."
echo "========================================"

API_APP_NAME="protected-api-demo"
API_APP_ID=$(az ad app create \
    --display-name "$API_APP_NAME" \
    --sign-in-audience "AzureADMyOrg" \
    --query appId -o tsv)

echo "✓ API App created: $API_APP_ID"

# Set Application ID URI
APP_ID_URI="api://$API_APP_ID"
az ad app update --id $API_APP_ID --identifier-uris "$APP_ID_URI"
echo "✓ Application ID URI set: $APP_ID_URI"

# Expose API scope
# This creates an OAuth2 delegated permission scope that allows the web app
# to call this API on behalf of a signed-in user. The scope definition includes:
# - Unique ID (SCOPE_ID): UUID to identify this permission
# - Type "User": Delegated permission (requires user sign-in, not application-only)
# - Value "access_as_user": The scope string used in token requests
# - Consent descriptions: What users/admins see when granting permission
#
# After this, the web app can request tokens with scope:
# api://{API_APP_ID}/access_as_user
#
# This is different from app roles (application permissions) which don't require
# a user context. Delegated permissions pass the user's identity to the API.
echo "✓ Exposing API scope: access_as_user"
SCOPE_ID=$(uuidgen)

# Create scope definition JSON
# oauth2PermissionScopes array defines what permissions this API exposes
cat > scope.json <<EOF
{
  "oauth2PermissionScopes": [{
    "adminConsentDescription": "Allows the web app to access the API on behalf of the signed-in user",
    "adminConsentDisplayName": "Access API as user",
    "id": "$SCOPE_ID",
    "isEnabled": true,
    "type": "User",
    "userConsentDescription": "Allows the web app to access the API on your behalf",
    "userConsentDisplayName": "Access API",
    "value": "access_as_user"
  }]
}
EOF

az ad app update --id $API_APP_ID --set api="@scope.json"

# Clean up temporary JSON file
# The scope.json was only needed for the az ad app update command above.
# The @ symbol tells Azure CLI to read JSON from a file. Now that the scope
# is registered in Entra ID, we don't need the local file anymore.
rm scope.json

echo "✓ Scope 'access_as_user' exposed"

# Create service principal for the API
# This is required for the API to be accessible by other applications in your tenant.
# Without a service principal, you'll get error AADSTS650052 when trying to consent
# to permissions for this API.
echo "✓ Creating service principal for API..."
az ad sp create --id $API_APP_ID --output none || echo "  (Service principal already exists)"

echo ""

# ============================================
# Step 2: Create Web App Registration
# ============================================
echo "Step 2: Creating Web App registration..."
echo "========================================"

WEB_APP_NAME="webapp-calls-api-demo"
REDIRECT_URI="http://localhost:5000/getAToken"

WEB_APP_ID=$(az ad app create \
    --display-name "$WEB_APP_NAME" \
    --sign-in-audience "AzureADMyOrg" \
    --web-redirect-uris "$REDIRECT_URI" \
    --enable-id-token-issuance true \
    --query appId -o tsv)

echo "✓ Web App created: $WEB_APP_ID"

# Create client secret for web app
WEB_CLIENT_SECRET=$(az ad app credential reset \
    --id $WEB_APP_ID \
    --append \
    --query password -o tsv)

echo "✓ Client secret created"
echo ""

# ============================================
# Step 3: Grant API Permissions
# ============================================
echo "Step 3: Granting API permissions..."
echo "========================================"

# Add API permission to web app
az ad app permission add \
    --id $WEB_APP_ID \
    --api $API_APP_ID \
    --api-permissions "$SCOPE_ID=Scope"

echo "✓ Permission added: api://$API_APP_ID/access_as_user"

# Grant admin consent
echo "✓ Attempting admin consent..."
az ad app permission admin-consent --id $WEB_APP_ID 2>/dev/null || \
    echo "⚠ Admin consent requires Global Administrator role (can be done later)"

echo ""
echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo ""

# Export environment variables
export CLIENT_ID="$WEB_APP_ID"
export CLIENT_SECRET="$WEB_CLIENT_SECRET"
export TENANT_ID="$TENANT_ID"
export API_CLIENT_ID="$API_APP_ID"

echo "Environment variables exported for web-app:"
echo "  CLIENT_ID=$WEB_APP_ID"
echo "  API_CLIENT_ID=$API_APP_ID"
echo "  TENANT_ID=$TENANT_ID"
echo ""
echo "Environment variables exported for API:"
echo "  TENANT_ID=$TENANT_ID"
echo "  API_CLIENT_ID=$API_APP_ID"
echo ""
echo "========================================"
echo "Next Steps:"
echo "========================================"
echo ""
echo "To run locally:"
echo "  1. source ./setup-entraid.sh (to export variables)"
echo "  2. cd api && pip install -r requirements.txt"
echo "  3. python app.py (in api/ directory) - starts on port 5001"
echo "  4. cd ../web-app && pip install -r requirements.txt"
echo "  5. python app.py (in web-app/ directory) - starts on port 5000"
echo "  6. Open http://localhost:5000"
echo ""
echo "To deploy to Azure Container Apps:"
echo "  ./deploy-to-azure.sh"
echo ""
