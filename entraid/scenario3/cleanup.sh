#!/bin/bash

# Cleanup Script for Scenario 3
# Removes Entra ID app registrations, managed identity, and optionally Azure resources

echo "========================================"
echo "Cleanup Scenario 3 Resources"
echo "========================================"
echo ""

# Check if environment variables are set
if [ -z "$CLIENT_ID" ] || [ -z "$API_CLIENT_ID" ]; then
    echo "Warning: Environment variables not set"
    echo "Please provide app IDs manually or source the .env file"
    echo ""
    read -p "Enter Web App Client ID (or press Enter to skip): " INPUT_CLIENT_ID
    read -p "Enter API Client ID (or press Enter to skip): " INPUT_API_CLIENT_ID
    
    if [ ! -z "$INPUT_CLIENT_ID" ]; then
        CLIENT_ID=$INPUT_CLIENT_ID
    fi
    if [ ! -z "$INPUT_API_CLIENT_ID" ]; then
        API_CLIENT_ID=$INPUT_API_CLIENT_ID
    fi
fi

# ============================================
# Step 1: Delete Entra ID App Registrations
# ============================================
echo "Step 1: Deleting Entra ID app registrations..."

if [ ! -z "$CLIENT_ID" ]; then
    echo "Deleting Web App registration ($CLIENT_ID)..."
    # Federated credentials are automatically deleted with the app
    az ad app delete --id $CLIENT_ID || echo "  ⚠ Failed to delete Web App (might not exist)"
    echo "✓ Web App registration deleted (federated credentials auto-deleted)"
else
    echo "⊘ Skipping Web App deletion (no CLIENT_ID)"
fi

if [ ! -z "$API_CLIENT_ID" ]; then
    echo "Deleting API registration ($API_CLIENT_ID)..."
    az ad app delete --id $API_CLIENT_ID || echo "  ⚠ Failed to delete API (might not exist)"
    echo "✓ API registration deleted"
else
    echo "⊘ Skipping API deletion (no API_CLIENT_ID)"
fi

echo ""

# ============================================
# Step 2: Clean up environment variables
# ============================================
echo "Step 2: Cleaning up environment variables..."
unset CLIENT_ID
unset TENANT_ID
unset API_CLIENT_ID
unset MANAGED_IDENTITY_CLIENT_ID

echo "✓ Environment variables cleared"
echo ""

# ============================================
# Step 3: Optional Azure Resource Cleanup
# ============================================
echo "========================================"
echo "Azure Resource Cleanup (Optional)"
echo "========================================"
echo ""
echo "If you deployed to Azure Container Apps, you may want to delete those resources."
echo ""

RESOURCE_GROUP="rg-webapp-api-fedcred-demo"

# Check if resource group exists
if az group exists --name $RESOURCE_GROUP 2>/dev/null | grep -q true; then
    echo "Resource group '$RESOURCE_GROUP' found."
    echo ""
    echo "This will delete:"
    echo "  - Container Apps (API and Web App)"
    echo "  - Container Apps Environment"
    echo "  - Azure Container Registry"
    echo "  - User-Assigned Managed Identity"
    echo "  - Log Analytics Workspace"
    echo "  - All associated resources"
    echo ""
    read -p "Delete resource group '$RESOURCE_GROUP'? (yes/no): " DELETE_CONFIRM
    
    if [ "$DELETE_CONFIRM" = "yes" ]; then
        echo "Deleting resource group..."
        az group delete --name $RESOURCE_GROUP --yes --no-wait
        echo "✓ Resource group deletion initiated (running in background)"
        echo "  Check status: az group show --name $RESOURCE_GROUP"
    else
        echo "⊘ Skipped resource group deletion"
        echo ""
        echo "To delete manually later:"
        echo "  az group delete --name $RESOURCE_GROUP --yes"
    fi
else
    echo "Resource group '$RESOURCE_GROUP' not found (already deleted or not created)"
fi

echo ""
echo "========================================"
echo "Cleanup Complete!"
echo "========================================"
echo ""
echo "Note: Managed Identity and Federated Credentials are deleted"
echo "automatically when the resource group and app registration are deleted."
echo ""
