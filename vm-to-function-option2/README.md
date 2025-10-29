# VM to Function App Authentication with Managed Identity

This guide demonstrates how to deploy a Linux Ubuntu VM with a user-assigned managed identity that authenticates to an Azure Function App running Python code, with the Function App configured to accept calls only from that specific managed identity.

**🔒 Security Note:** This implementation uses **managed identities for storage access** (no storage keys), following best practices for organizations that disable shared key access on storage accounts.

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│  Linux Ubuntu VM (D2s_v3)                      │
│  ┌────────────────────────────────────┐        │
│  │  User-Assigned Managed Identity     │        │
│  │  (id-vm-to-function)                │        │
│  │  - Gets access token from IMDS      │        │
│  │  - Authenticates to Function App    │        │
│  └────────────────────────────────────┘        │
└─────────────────────────────────────────────────┘
                    │
                    │ HTTPS with Bearer Token
                    ▼
┌─────────────────────────────────────────────────┐
│  Azure Function App (Python)                    │
│  ┌────────────────────────────────────┐        │
│  │  Code-Based JWT Validation         │        │
│  │  - Validates JWT signature          │        │
│  │  - Checks expiration, audience      │        │
│  │  - Validates client ID match        │        │
│  │  - No Easy Auth required!           │        │
│  └────────────────────────────────────┘        │
│  ┌────────────────────────────────────┐        │
│  │  Storage Access (No Keys) 🔒       │        │
│  │  User-Assigned Managed Identity     │        │
│  │  (func-host-storage-user)           │        │
│  │  - Storage Blob Data Owner role     │        │
│  └────────────────────────────────────┘        │
└─────────────────────────────────────────────────┘
                    │
                    │ Managed Identity Auth
                    ▼
┌─────────────────────────────────────────────────┐
│  Storage Account                                │
│  - Shared key access: DISABLED 🔒              │
│  - Access via managed identity only             │
└─────────────────────────────────────────────────┘
```

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- Appropriate permissions to create resources
- Python 3.8+ installed locally (for testing Function App)
- **jq** JSON processor installed (`sudo apt-get install jq` on Ubuntu)
- Basic knowledge of Azure resources
- Organization policy that allows managed identity for storage access

---

## Step 1: Set Environment Variables

First, define your environment variables for consistent naming:

```bash
# Set your variables
RESOURCE_GROUP="rg-vm-function-demo"
LOCATION="eastus2"
VM_NAME="vm-ubuntu-demo"
VM_SIZE="Standard_D2s_v3"  # 2 vCPUs, 8 GB RAM
MANAGED_IDENTITY_NAME="id-vm-to-function"
FUNC_STORAGE_IDENTITY_NAME="func-host-storage-user"  # Standard name for function storage identity
FUNCTION_APP_NAME="func-secure-demo-$(date +%s)"  # Must be globally unique
STORAGE_ACCOUNT_NAME="stfunc$(date +%s | tail -c 8)"  # Must be globally unique
VNET_NAME="vnet-demo"
SUBNET_NAME="subnet-vm"
NSG_NAME="nsg-vm"

# Display the values
echo "Resource Group: $RESOURCE_GROUP"
echo "VM Managed Identity: $MANAGED_IDENTITY_NAME"
echo "Function Storage Identity: $FUNC_STORAGE_IDENTITY_NAME"
echo "Function App: $FUNCTION_APP_NAME"
echo "Storage Account: $STORAGE_ACCOUNT_NAME"
```

---

## Step 2: Create Resource Group

```bash
# Create the resource group
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

echo "✅ Resource group created: $RESOURCE_GROUP"
```

---

## Step 3: Create User-Assigned Managed Identity

```bash
# Create the user-assigned managed identity
az identity create \
  --name $MANAGED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

# Get the identity details (we'll need these later)
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

echo "✅ Managed Identity Created"
echo "   Identity ID: $IDENTITY_ID"
echo "   Client ID: $IDENTITY_CLIENT_ID"
echo "   Principal ID: $IDENTITY_PRINCIPAL_ID"
```

---

## Step 4: Create Virtual Network and Subnet

```bash
# Create virtual network
az network vnet create \
  --name $VNET_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --address-prefix 10.0.0.0/16 \
  --subnet-name $SUBNET_NAME \
  --subnet-prefix 10.0.1.0/24

# Create Network Security Group
az network nsg create \
  --name $NSG_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

# Allow SSH (you can restrict this to your IP)
az network nsg rule create \
  --name AllowSSH \
  --nsg-name $NSG_NAME \
  --resource-group $RESOURCE_GROUP \
  --priority 1000 \
  --source-address-prefixes '*' \
  --destination-port-ranges 22 \
  --protocol Tcp \
  --access Allow

# Allow outbound HTTPS (for accessing Function App)
az network nsg rule create \
  --name AllowHTTPS \
  --nsg-name $NSG_NAME \
  --resource-group $RESOURCE_GROUP \
  --priority 1001 \
  --direction Outbound \
  --source-address-prefixes '*' \
  --destination-port-ranges 443 \
  --protocol Tcp \
  --access Allow

# Associate NSG with subnet
az network vnet subnet update \
  --name $SUBNET_NAME \
  --vnet-name $VNET_NAME \
  --resource-group $RESOURCE_GROUP \
  --network-security-group $NSG_NAME

echo "✅ Virtual network and NSG created"
```

---

## Step 5: Create Ubuntu VM with Managed Identity

```bash
# Create the VM with user-assigned managed identity
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
  --public-ip-sku Standard

# Get the VM's public IP
VM_PUBLIC_IP=$(az vm show \
  --name $VM_NAME \
  --resource-group $RESOURCE_GROUP \
  --show-details \
  --query publicIps -o tsv)

echo "✅ VM Created"
echo "   VM Name: $VM_NAME"
echo "   Public IP: $VM_PUBLIC_IP"
echo "   SSH Command: ssh azureuser@$VM_PUBLIC_IP"
```

---

## Step 6: Create Storage Account for Function App (Without Storage Keys)

**Important**: This follows the secure approach for organizations that prevent storage key usage.

```bash
# Create storage account with shared key access disabled
az storage account create \
  --name $STORAGE_ACCOUNT_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --allow-blob-public-access false \
  --allow-shared-key-access false

echo "✅ Storage account created: $STORAGE_ACCOUNT_NAME (without shared key access)"
```

---

## Step 7: Create Function App with Managed Identity for Storage Access

**Important**: The Function App will use managed identity to access storage instead of storage keys.

```bash
# Step 7a: Create user-assigned managed identity for Function App storage access
FUNC_STORAGE_IDENTITY_NAME="func-host-storage-user"

az identity create \
  --name $FUNC_STORAGE_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

# Step 7b: Get identity details
output=$(az identity show \
  --name $FUNC_STORAGE_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query "{userId:id, principalId: principalId, clientId: clientId}" -o json)

FUNC_STORAGE_USER_ID=$(echo $output | jq -r '.userId')
FUNC_STORAGE_PRINCIPAL_ID=$(echo $output | jq -r '.principalId')
FUNC_STORAGE_CLIENT_ID=$(echo $output | jq -r '.clientId')

echo "Storage Identity Created:"
echo "  Client ID: $FUNC_STORAGE_CLIENT_ID"
echo "  Principal ID: $FUNC_STORAGE_PRINCIPAL_ID"

# Step 7c: Assign Storage Blob Data Owner role to the managed identity
STORAGE_ID=$(az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT_NAME \
  --query 'id' -o tsv)

az role assignment create \
  --assignee-object-id $FUNC_STORAGE_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Owner" \
  --scope $STORAGE_ID

echo "✅ Storage role assigned to managed identity"

# Step 7d: Create Function App using Flex Consumption plan with managed identity
az functionapp create \
  --resource-group $RESOURCE_GROUP \
  --flexconsumption-location $LOCATION \
  --runtime python \
  --runtime-version 3.11 \
  --storage-account $STORAGE_ACCOUNT_NAME \
  --name $FUNCTION_APP_NAME \
  --deployment-storage-auth-type UserAssignedIdentity \
  --deployment-storage-auth-value $FUNC_STORAGE_IDENTITY_NAME

echo "✅ Function App created: $FUNCTION_APP_NAME"

# Step 7e: Configure AzureWebJobsStorage with managed identity
az functionapp config appsettings set \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --settings AzureWebJobsStorage__accountName=$STORAGE_ACCOUNT_NAME \
  AzureWebJobsStorage__credential=managedidentity \
  AzureWebJobsStorage__clientId=$FUNC_STORAGE_CLIENT_ID

# Step 7f: Remove the connection string setting (forces managed identity usage)
az functionapp config appsettings delete \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --setting-names AzureWebJobsStorage 2>/dev/null || true

# Get the Function App URL
FUNCTION_APP_URL="https://${FUNCTION_APP_NAME}.azurewebsites.net"

echo "✅ Function App configured with managed identity for storage"
echo "   URL: $FUNCTION_APP_URL"
echo "   Storage Access: Managed Identity (no keys)"
```

---

## Step 8: Configure Function App for Code-Based Authentication

**Important:** Managed identities need to request tokens from Entra ID for a specific resource. We create an **Azure AD App Registration to define a resource in Entra ID** that represents our Function App API. This allows the VM's managed identity to request tokens with the correct audience claim. We will use **code-based JWT validation** instead of Easy Auth for better control and debugging.

```bash
# Step 8a: Create Azure AD App Registration for the Function App API (Resource)
echo "Creating Azure AD App Registration for Function App API..."

# Get tenant ID
TENANT_ID=$(az account show --query tenantId -o tsv)

# Create app registration (represents the Function App API resource)
APP_REG_NAME="${FUNCTION_APP_NAME}-app"
APP_ID=$(az ad app create \
  --display-name $APP_REG_NAME \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)

echo "✅ App Registration created (Function App API Resource)"
echo "   App ID: $APP_ID"

# Step 8b: Set the Application ID URI (required for managed identity token requests)
az ad app update --id $APP_ID --identifier-uris "api://${APP_ID}"

echo "✅ Application ID URI set: api://${APP_ID}"

# About Application ID URI formats:
# ✅ api://{APP_ID} (used here)
#    - Microsoft's recommended default
#    - Simple, unique, guaranteed to not conflict
#    - No DNS requirements
#    - Works immediately
#
# Alternative: https://{verified-domain}/{path}
#    - Requires verified domain in Entra ID tenant
#    - Looks like a "real" API URL
#    - Common for public-facing APIs
#    - Must match verified domains in your tenant

# Step 8c: Create Service Principal for the App Registration (API Resource)
# NOTE: When using Azure Portal, the Service Principal is auto-created.
# When using Azure CLI, you must explicitly create it with 'az ad sp create'.
# This is required for token requests to work - Entra ID needs the Service Principal
# to recognize api://{APP_ID} as a valid resource in your tenant.
SP_ID=$(az ad sp create --id $APP_ID --query id -o tsv)

echo "✅ Service Principal created (for Function App API Resource)"
echo "   Service Principal Object ID: $SP_ID"
echo "   Note: This SP represents the API resource, NOT the VM identity"

# Step 8d: Set environment variables for code-based JWT validation
az functionapp config appsettings set \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --settings \
    TENANT_ID=$TENANT_ID \
    APP_ID=$APP_ID \
    ALLOWED_CLIENT_ID=$IDENTITY_CLIENT_ID

echo "✅ Environment variables configured:"
echo "   TENANT_ID: $TENANT_ID"
echo "   APP_ID (API Resource): $APP_ID"
echo "   ALLOWED_CLIENT_ID (VM Identity): $IDENTITY_CLIENT_ID"
```

**Note:** Easy Auth is not used or configured in this setup.

**Why Code-Based Validation (No Easy Auth)?**
- ✅ **Full control** over authentication logic
- ✅ **Better debugging** - see exactly why tokens fail
- ✅ **Detailed error messages** - expired, wrong audience, invalid signature, etc.
- ✅ **Flexible validation** - can validate any claims you want
- ✅ **No platform dependencies** - pure Python code - security is intact when moved to a different hosting platform
- ✅ **Better logging** - see what's happening at each step

---

## Step 9: Deploy Python Function Code with JWT Token Validation

The function code will manually validate JWT tokens and check that requests come from the specific VM managed identity.

### 9.1: Navigate to Function Code Directory

The function code is already prepared in `function-app-code/`.

### 9.2: Update Function Code

The function code in `function_app.py` validates JWT tokens manually (no Easy Auth needed):

```python
import azure.functions as func
import logging
import json
import os
import jwt
import requests
from datetime import datetime
from functools import lru_cache

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

@lru_cache(maxsize=1)
def get_jwks_keys(tenant_id):
    """
    Fetch and cache the public keys from Azure AD for JWT verification.
    """
    jwks_url = f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys"
    response = requests.get(jwks_url, timeout=10)
    return response.json()

def validate_jwt_token(token, tenant_id, expected_audience):
    """
    Validate JWT token:
    1. Verify signature using Azure AD's public keys
    2. Verify expiration, audience, and issuer
    """
    try:
        # Get key ID from token header
        unverified_header = jwt.get_unverified_header(token)
        kid = unverified_header.get('kid')
        
        # Get Azure AD's public keys and find matching key
        jwks = get_jwks_keys(tenant_id)
        signing_key = None
        for key in jwks.get('keys', []):
            if key.get('kid') == kid:
                signing_key = jwt.algorithms.RSAAlgorithm.from_jwk(json.dumps(key))
                break
        
        if not signing_key:
            return None, f"Signing key not found"
        
        # Verify and decode the token
        decoded_token = jwt.decode(
            token,
            signing_key,
            algorithms=['RS256'],
            audience=expected_audience,
            issuer=f'https://sts.windows.net/{tenant_id}/',
            options={'verify_signature': True, 'verify_exp': True, 'verify_aud': True, 'verify_iss': True}
        )
        
        return decoded_token, None
        
    except jwt.ExpiredSignatureError:
        return None, "Token has expired"
    except jwt.InvalidAudienceError:
        return None, f"Invalid audience"
    except Exception as e:
        return None, f"Token validation error: {str(e)}"

@app.route(route="HttpTrigger", methods=["GET", "POST"])
def HttpTrigger(req: func.HttpRequest) -> func.HttpResponse:
    """
    HTTP trigger with manual JWT validation.
    No Easy Auth required - all validation done in code.
    """
    logging.info('Processing request with code-based JWT validation')
    
    # Get configuration
    allowed_client_id = os.environ.get('ALLOWED_CLIENT_ID', '')
    tenant_id = os.environ.get('TENANT_ID', '')
    app_id = os.environ.get('APP_ID', '')
    
    # Extract Bearer token
    auth_header = req.headers.get('Authorization', '')
    if not auth_header.startswith('Bearer '):
        return func.HttpResponse(
            json.dumps({"error": "Authentication required", "message": "Bearer token required"}),
            status_code=401, mimetype="application/json"
        )
    
    token = auth_header[7:]  # Remove 'Bearer '
    
    # Validate JWT token
    expected_audience = f'api://{app_id}'
    decoded_token, error = validate_jwt_token(token, tenant_id, expected_audience)
    
    if error:
        logging.warning(f'Token validation failed: {error}')
        return func.HttpResponse(
            json.dumps({"error": "Invalid token", "message": error}),
            status_code=401, mimetype="application/json"
        )
    
    # Extract identity from token
    caller_appid = decoded_token.get('appid')  # For service principals/managed identities
    caller_azp = decoded_token.get('azp')      # Authorized party
    caller_oid = decoded_token.get('oid')      # Object ID
    caller_client_id = caller_appid or caller_azp or caller_oid
    
    # Validate against allowed client ID
    if allowed_client_id and caller_client_id != allowed_client_id:
        logging.warning(f'Unauthorized: {caller_client_id} != {allowed_client_id}')
        return func.HttpResponse(
            json.dumps({
                "error": "Forbidden",
                "message": f"Client ID {caller_client_id} not authorized",
                "debug_info": {"caller": caller_client_id, "expected": allowed_client_id}
            }),
            status_code=403, mimetype="application/json"
        )
    
    # Success response
    return func.HttpResponse(
        json.dumps({
            "message": "Successfully authenticated!",
            "authenticated": True,
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "caller_info": {
                "client_id": caller_client_id,
                "object_id": caller_oid,
                "appid_claim": caller_appid,
                "azp_claim": caller_azp
            },
            "token_info": {
                "audience": decoded_token.get('aud'),
                "issuer": decoded_token.get('iss'),
                "issued_at": datetime.fromtimestamp(decoded_token.get('iat', 0)).isoformat(),
                "expires_at": datetime.fromtimestamp(decoded_token.get('exp', 0)).isoformat()
            },
            "validation": {
                "allowed_client_id": allowed_client_id,
                "client_id_match": caller_client_id == allowed_client_id,
                "method": "code-based-jwt-validation"
            }
        }, indent=2),
        status_code=200, mimetype="application/json"
    )
```

### 9.3: Update requirements.txt

Add JWT validation dependencies:

```
azure-functions
PyJWT[crypto]>=2.8.0
requests>=2.31.0
cryptography>=41.0.0
```

### 9.4: Deploy Function to Azure

```bash
# Deploy the function
cd function-app-code
func azure functionapp publish $FUNCTION_APP_NAME

echo "✅ Function deployed successfully"
echo "   Function URL: ${FUNCTION_APP_URL}/api/HttpTrigger"
echo "   Authentication: Code-based JWT validation (no Easy Auth)"
```

### 9.5: Test Unauthorized Access from Local Machine

Before testing from the VM, let's verify that unauthorized access is properly blocked:

```bash
# Try to access without any authentication
curl -i "https://${FUNCTION_APP_NAME}.azurewebsites.net/api/HttpTrigger"
```

**Expected Output:**
```
HTTP/1.1 401 Unauthorized
Content-Type: application/json

{"error": "Authentication required", "message": "Bearer token required"}
```

✅ **This confirms the function requires Bearer token authentication**

---

## Step 10: Install Required Tools on the VM

SSH into the VM and install necessary tools:

```bash
# SSH into the VM
ssh azureuser@$VM_PUBLIC_IP

# Once connected, run these commands:
sudo apt-get update
sudo apt-get install -y curl jq

# Verify you can reach the metadata service
curl -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | jq
```

---

## Step 11: Create Test Script on VM

On the VM, create a script to get a token and call the Function App.

**Important:** You'll need the App ID from Step 8. Get it first:

```bash
# On your local machine, get the App ID
APP_ID=$(az ad app list --display-name "${FUNCTION_APP_NAME}-app" --query "[0].appId" -o tsv)
echo "App ID (Function App API Resource): $APP_ID"
echo "Use this App ID in the VM script below"
```

Now, SSH to the VM and create the test script:

```bash
# SSH into the VM
ssh azureuser@$VM_PUBLIC_IP

# On the VM, create the test script
cat > call-function.sh << 'EOF'
#!/bin/bash

# Function App URL
FUNCTION_APP_URL="${1:-https://your-function-app.azurewebsites.net}"
# App ID from App Registration (you'll pass this as second parameter)
APP_ID="${2}"

if [ -z "$APP_ID" ]; then
    echo "❌ Error: App ID is required"
    echo "Usage: $0 <FUNCTION_APP_URL> <APP_ID>"
    echo "Example: $0 https://func-xxx.azurewebsites.net aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    exit 1
fi

# Use api:// scheme for App Registration resource
RESOURCE="api://${APP_ID}"

echo "=========================================="
echo "VM to Function App Authentication Test"
echo "=========================================="
echo "Function App URL: $FUNCTION_APP_URL"
echo "Resource (App ID): $RESOURCE"
echo

# Step 1: Get access token from Azure IMDS
echo "Step 1: Getting access token from Azure Instance Metadata Service..."

TOKEN_RESPONSE=$(curl -s -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=${RESOURCE}")

if [ $? -ne 0 ]; then
    echo "❌ Failed to get token from IMDS"
    exit 1
fi

ACCESS_TOKEN=$(echo $TOKEN_RESPONSE | jq -r '.access_token')

if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo "❌ Failed to extract access token"
    echo "Response: $TOKEN_RESPONSE"
    exit 1
fi

echo "✅ Access token obtained"
echo "Token preview: ${ACCESS_TOKEN:0:50}..."

if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo "❌ Failed to extract access token"
    echo "Response: $TOKEN_RESPONSE"
    exit 1
fi

echo "✅ Access token obtained"
echo "Token preview: ${ACCESS_TOKEN:0:50}..."
echo

# Step 2: Call the Function App with the token
echo "Step 2: Calling Function App with access token..."
echo "URL: ${FUNCTION_APP_URL}/api/HttpTrigger"
echo

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  "${FUNCTION_APP_URL}/api/HttpTrigger")

HTTP_STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | sed '/HTTP_STATUS/d')

echo "HTTP Status: $HTTP_STATUS"
echo
echo "Response Body:"
echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
echo

if [ "$HTTP_STATUS" == "200" ]; then
    echo "✅ Successfully authenticated and called Function App!"
else
    echo "❌ Failed to call Function App (HTTP $HTTP_STATUS)"
fi

echo "=========================================="
EOF

# Make it executable
chmod +x call-function.sh

echo "✅ Test script created: call-function.sh"
```

---

## Step 12: Test the Authentication

### From the VM:

First, you need the App ID from your local machine:

```bash
# On your LOCAL machine, get the App ID
APP_ID=$(az ad app list --display-name "${FUNCTION_APP_NAME}-app" --query "[0].appId" -o tsv)
echo "App ID (Function App API Resource): $APP_ID"
echo ""
echo "Run this command on the VM:"
echo "./call-function.sh \"https://${FUNCTION_APP_NAME}.azurewebsites.net\" \"$APP_ID\""
```

Then, on the VM:

```bash
# Run the test script with Function App URL and App ID
./call-function.sh "https://<your-function-app>.azurewebsites.net" "<app-id-from-above>"

# Example:
# ./call-function.sh "https://func-secure-demo-1761665150.azurewebsites.net" "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
```

**Expected Output:**
```
==========================================
VM to Function App Authentication Test
==========================================
Function App URL: https://func-secure-demo-xxx.azurewebsites.net
Resource (App ID): api://a1b2c3d4-e5f6-7890-abcd-ef1234567890

Step 1: Getting access token from Azure Instance Metadata Service...
✅ Access token obtained
Token preview: eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsIng1dCI6...

Step 2: Calling Function App with access token...
URL: https://func-secure-demo-xxx.azurewebsites.net/api/HttpTrigger

HTTP Status: 200

Response Body:
{
  "message": "Successfully authenticated!",
  "authenticated": true,
  "timestamp": "2025-10-28T18:28:24.999178Z",
  "caller_info": {
    "client_id": "141e40aa-4da8-464d-925d-4db5585a1284",
    "object_id": "c4b8df12-25c0-481f-82f0-36bc434bf352",
    "subject": "c4b8df12-25c0-481f-82f0-36bc434bf352",
    "appid_claim": "141e40aa-4da8-464d-925d-4db5585a1284",
    "azp_claim": null
  },
  "token_info": {
    "audience": "api://a1676f1e-6812-4870-9ad8-b5fe5323c393",
    "issuer": "https://sts.windows.net/d12058fe-ecf4-454a-9a69-cef5686fc24f/",
    "issued_at": "2025-10-28T18:01:04",
    "expires_at": "2025-10-29T18:06:04"
  },
  "validation": {
    "allowed_client_id": "141e40aa-4da8-464d-925d-4db5585a1284",
    "client_id_match": true,
    "claim_used": "appid",
    "method": "code-based-jwt-validation"
  }
}

✅ Successfully authenticated and called Function App!
==========================================
```

### Test Unauthorized Access (from local machine):

```bash
# Try to call without authentication - should fail with 401
curl -i "https://${FUNCTION_APP_NAME}.azurewebsites.net/api/HttpTrigger"

# Expected: HTTP/1.1 401 Unauthorized
```

---

## Step 13: Verify Security Configuration

### Check Function App Authentication Settings:

```bash
# View authentication settings
az webapp auth show \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query "{enabled:enabled, defaultProvider:defaultProvider, action:unauthenticatedClientAction}" \
  -o table
```

### Check Managed Identity Assignments:

```bash
# List role assignments for the managed identity
az role assignment list \
  --assignee $IDENTITY_PRINCIPAL_ID \
  --query "[].{Role:roleDefinitionName, Scope:scope}" \
  -o table
```

---

## Advanced: Using Client Credentials Flow with App Roles

For more fine-grained control and/or additional controls, you can use **Entra ID app roles**. These are **API-specific roles** tied to your App Registration (the API resource in Entra ID), not Azure RBAC roles.

**Important Concepts:**

- **App roles are properties of the App Registration (API Resource)** - they define what permissions your API offers
- **App roles are NOT separate objects** - they're metadata within the App Registration
- **Two-step process**: (1) Define the roles on the API, (2) Assign them to caller identities
- **No immediate association** - defining a role doesn't grant it to anyone automatically
- **Defense-in-depth** - restricts token issuance at Entra ID level (in addition to your code validation)

**Entra ID Objects Structure:**

```
Function App API Resource (App Registration)
├── appId: "abc-123" ($APP_ID)
├── identifierUris: ["api://abc-123"]
└── appRoles: [                          ← Step 1: Define roles here
      {
        "id": "xyz-789",
        "value": "Function.Invoke",
        "allowedMemberTypes": ["Application"]
      }
    ]

Function App API Resource (Service Principal)
├── id: "sp-object-id" ($SP_ID)
└── appRoleAssignedTo: [                 ← Step 2: Assign roles here
      {
        "principalId": "vm-identity-principal-id" ($IDENTITY_PRINCIPAL_ID),
        "appRoleId": "xyz-789"           ← References the role above
      }
    ]

VM Managed Identity (Caller)
├── clientId: "vm-client-id" ($IDENTITY_CLIENT_ID)
├── principalId: "vm-principal-id" ($IDENTITY_PRINCIPAL_ID)
└── Requests tokens for: api://abc-123
```

### Security Architecture Evolution

The following steps demonstrate a **defense-in-depth approach** with multiple security layers:

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Step 1: Define App Role (API Resource Configuration)                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Entra ID - App Registration (API Resource)                            │
│  ┌─────────────────────────────────────────────────────┐              │
│  │ api://abc-123                                        │              │
│  │ ┌─────────────────────────────────────────────────┐ │              │
│  │ │ App Roles (Metadata)                            │ │              │
│  │ │ - Function.Invoke (id: xyz-789)                 │ │              │
│  │ │ - allowedMemberTypes: ["Application"]           │ │              │
│  │ │ - isEnabled: true                               │ │              │
│  │ └─────────────────────────────────────────────────┘ │              │
│  └─────────────────────────────────────────────────────┘              │
│                                                                         │
│  ⚠️  No security enforcement yet - just metadata                       │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ Step 2: Assign Role to VM Identity (Grant Permission)                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Entra ID - Service Principal (API Resource)                           │
│  ┌─────────────────────────────────────────────────────┐              │
│  │ api://abc-123 (Service Principal)                   │              │
│  │ ┌─────────────────────────────────────────────────┐ │              │
│  │ │ appRoleAssignedTo:                              │ │              │
│  │ │ ┌─────────────────────────────────────────────┐ │ │              │
│  │ │ │ ✓ VM Identity (principalId: vm-123)        │ │ │              │
│  │ │ │   appRoleId: xyz-789                       │ │ │              │
│  │ │ └─────────────────────────────────────────────┘ │ │              │
│  │ └─────────────────────────────────────────────────┘ │              │
│  │                                                      │              │
│  │ appRoleAssignmentRequired: false (default)          │              │
│  └─────────────────────────────────────────────────────┘              │
│                                                                         │
│  ⚠️  VM gets tokens WITH role claim, but OTHER identities also get    │
│      tokens WITHOUT role claim - your app code must validate!          │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ Step 3a-3b: Default Behavior (BEFORE appRoleAssignmentRequired)        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  VM Identity (Authorized)          Temp Identity (Unauthorized)        │
│  ┌────────────────────┐             ┌────────────────────┐            │
│  │ Has app role       │             │ NO app role        │            │
│  │ assigned           │             │                    │            │
│  └────────┬───────────┘             └─────────┬──────────┘            │
│           │                                   │                        │
│           │ Token Request                     │ Token Request          │
│           ▼                                   ▼                        │
│  ┌─────────────────────────────────────────────────────┐              │
│  │ Entra ID (Token Issuance)                           │              │
│  │ appRoleAssignmentRequired: false                    │              │
│  └─────────────────────────────────────────────────────┘              │
│           │                                   │                        │
│           │ ✅ Token with role               │ ✅ Token without role  │
│           │    roles: ["Function.Invoke"]    │    (no roles claim)    │
│           │                                   │                        │
│           └───────────┬───────────────────────┘                        │
│                       ▼                                                │
│            ┌─────────────────────┐                                     │
│            │ Function App        │                                     │
│            │ (Your Code)         │                                     │
│            │ - Validates JWT     │ ← 🔒 Layer 1: Your code validates  │
│            │ - Checks client_id  │    client ID, signature, audience  │
│            │ - (Optional) roles  │    Must check roles claim!         │
│            └─────────────────────┘                                     │
│                                                                         │
│  ⚠️  SECURITY ISSUE: ANY identity can get tokens from Entra ID!       │
│      Your app must validate to block unauthorized callers              │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ Step 3c-3d: Enhanced Security (AFTER appRoleAssignmentRequired=true)   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  VM Identity (Authorized)          Temp Identity (Unauthorized)        │
│  ┌────────────────────┐             ┌────────────────────┐            │
│  │ Has app role       │             │ NO app role        │            │
│  │ assigned           │             │                    │            │
│  └────────┬───────────┘             └─────────┬──────────┘            │
│           │                                   │                        │
│           │ Token Request                     │ Token Request          │
│           ▼                                   ▼                        │
│  ┌─────────────────────────────────────────────────────┐              │
│  │ Entra ID (Token Issuance)                           │              │
│  │ appRoleAssignmentRequired: true                     │              │
│  │                                                      │              │
│  │ Checks: Does caller have assigned app role?         │              │
│  └─────────────────────────────────────────────────────┘              │
│           │                                   │                        │
│           │ ✅ Token with role               │ ❌ DENIED               │
│           │    roles: ["Function.Invoke"]    │    AADSTS501051        │
│           │                                   │                        │
│           ▼                                   X (blocked)              │
│  ┌─────────────────────┐                                              │
│  │ Function App        │                                              │
│  │ (Your Code)         │ ← 🔒 Layer 2: Your code validates           │
│  │ - Validates JWT     │    (Defense in depth)                        │
│  │ - Checks client_id  │                                              │
│  │ - (Optional) roles  │                                              │
│  └─────────────────────┘                                              │
│                                                                         │
│  ✅ SECURITY ENFORCED: Entra ID blocks unauthorized token requests!   │
│                         🔒 Layer 1: Entra ID enforcement               │
│                         🔒 Layer 2: Application validation             │
└─────────────────────────────────────────────────────────────────────────┘
```

**Security Layers Summary:**

| Layer | Enforcement Point | What It Does | When Active |
|-------|------------------|--------------|-------------|
| **Layer 1: Entra ID** | Token Issuance | Blocks unauthorized identities from getting tokens | After `appRoleAssignmentRequired=true` |
| **Layer 2: Function Code** | JWT Validation | Validates token signature, audience, expiration, client ID | Always active |
| **Layer 3: Function Code** | Roles Check (Optional) | Validates `roles` claim in token | If implemented in code |

**Best Practice:** Use **both layers** for defense-in-depth:
- ✅ Set `appRoleAssignmentRequired=true` (blocks at token issuance)
- ✅ Validate JWT in application code (validates token integrity and claims)

---

### 1. Update App Registration with App Role (Define the Role on API Resource)

```bash
# Create app role definition for the Function App API
cat > app-roles.json << EOF
[
  {
    "allowedMemberTypes": ["Application"],
    "description": "Allows the VM to invoke functions",
    "displayName": "Function.Invoke",
    "id": "$(uuidgen)",
    "isEnabled": true,
    "value": "Function.Invoke"
  }
]
EOF

# Update app registration (Function App API Resource)
az ad app update --id $APP_ID --app-roles @app-roles.json

echo "✅ App role 'Function.Invoke' defined in App Registration (API Resource)"
echo "   Note: Role is defined but NOT yet assigned to any caller identity"
```

**What happened:**
- App role definition added to the App Registration (Function App API Resource)
- No caller identities have this role yet
- Tokens will not include the role until it's assigned to a caller

### 2. Assign Managed Identity to App Role (Grant the Role to VM Identity)

**Important:** This step uses `az rest` because there's no dedicated Azure CLI command for assigning **Entra ID app roles** (unlike Azure RBAC roles which use `az role assignment create`). We must call the Microsoft Graph API directly.

```bash

# View available app roles in the App Registration (Function App API Resource)
az ad app show --id $APP_ID --query "appRoles[].{id:id, value:value, displayName:displayName}" -o table


# Get the service principal ID for the app registration (API Resource SP)
SP_ID=$(az ad sp show --id $APP_ID --query id -o tsv)

# This section provides an equivalent role assignment for Azure resources roles
# Azure RBAC role assignment (this EXISTS):
# az role assignment create \
#  --assignee $IDENTITY_PRINCIPAL_ID \
#  --role "Storage Blob Data Owner" \
#  --scope $STORAGE_ID

# Hypothetical Entra ID app role assignment (DOES NOT EXIST - so use az rest):
# az ad app role assignment create \
#  --assignee $IDENTITY_PRINCIPAL_ID \      ← VM Managed Identity (Caller)
#  --app-role "Function.Invoke" \
#  --resource $APP_ID                       ← Function App API Resource


# Assign the VM managed identity to the app role on the API
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${IDENTITY_PRINCIPAL_ID}/appRoleAssignments" \
  --body "{
    \"principalId\": \"${IDENTITY_PRINCIPAL_ID}\",
    \"resourceId\": \"${SP_ID}\",
    \"appRoleId\": \"746c20c8-ac75-44dd-8864-6afab4399c65\"
  }"

echo "✅ App role assigned to VM managed identity (Caller)"
echo "   The VM can now request tokens with this role for the API"
```

**What happened:**
- VM's managed identity (Caller) now has the "Function.Invoke" app role for the API
- Entra ID will issue tokens for this identity
- Tokens will include the role in the `roles` claim
- Tokens issued to other identities without this role assignment will not include the role in the roles claim. Your application code must validate the roles claim to enforce access control

**Result:** Two-layer security:
1. **Entra ID layer** - Tokens include role information
2. **Application layer** - Your code validates token and checks client ID + roles claim

### 3. (Optional) Require Role Assignment for Token Issuance

**Important:** By default, Entra ID will issue tokens to ANY identity that requests them, even without app role assignments. To enforce that ONLY identities with assigned roles can get tokens, enable `appRoleAssignmentRequired` on the Service Principal (API Resource).

#### Step 3a: Create Test Identity to Demonstrate Default Behavior

**Why we need this:** The Azure Instance Metadata Service (IMDS) caches tokens for up to 1 hour. To test the security changes immediately, we'll create a **fresh managed identity** that has no cached tokens.

```bash
# Create a temporary third managed identity (simulates unauthorized caller)
# This identity will NOT be assigned any app role
TEMP_IDENTITY_NAME="id-test-unauthorized-$(date +%s)"

az identity create \
  --name $TEMP_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

# Get the identity details
TEMP_IDENTITY_ID=$(az identity show \
  --name $TEMP_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

TEMP_CLIENT_ID=$(az identity show \
  --name $TEMP_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query clientId -o tsv)

# Assign this identity to the VM (so we can test from the same VM)
az vm identity assign \
  --name $VM_NAME \
  --resource-group $RESOURCE_GROUP \
  --identities $TEMP_IDENTITY_ID

echo "✅ Temporary test identity created and assigned to VM"
echo "   Client ID: $TEMP_CLIENT_ID"
echo "   This identity has NO app role assignment"
echo ""
echo "📋 Current VM identities:"
echo "   1. $IDENTITY_CLIENT_ID (authorized - has app role)"
echo "   2. $TEMP_CLIENT_ID (unauthorized - no app role)"
echo ""
```

#### Step 3b: Test Default Behavior (Any Identity Can Get Tokens)

Now test from the VM that the unauthorized identity can get tokens:

```bash
echo "Copy this command and run it on the VM to test BEFORE enabling requirement:"
echo ""
echo "curl -s -H Metadata:true \"http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=api://${APP_ID}&client_id=${TEMP_CLIENT_ID}\" | jq"
echo ""
echo "Expected: ✅ Token successfully obtained (even though identity has no app role)"
```

**On the VM, you should see:**
```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGc...",
  "expires_in": "3599",
  "expires_on": "1730148427",
  "resource": "api://5356ae51-ddad-4dda-b012-b3a1dd728d73",
  "token_type": "Bearer"
}
```

✅ **This proves the security issue:** Any identity can get tokens by default, even without app role assignments!

✅ **This proves the security issue:** Any identity can get tokens by default, even without app role assignments!

#### Step 3c: Enable App Role Assignment Requirement

Now, let's enforce that ONLY identities with assigned app roles can get tokens:

```bash
# Require app role assignment for token issuance to the API
az ad sp update --id $SP_ID --set appRoleAssignmentRequired=true

echo "✅ App role assignment now REQUIRED for token issuance to the API"
echo "   Only identities with assigned app roles can request tokens for api://${APP_ID}"
echo ""
```

#### Step 3d: Verify Unauthorized Identity is Now Blocked

Test again from the VM with the unauthorized identity:

```bash
echo "Copy this command and run it on the VM to test AFTER enabling requirement:"
echo ""
echo "curl -s -H Metadata:true \"http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=api://${APP_ID}&client_id=${TEMP_CLIENT_ID}\" | jq"
echo ""
echo "Expected: ❌ Token request BLOCKED with AADSTS501051 error"
```

**On the VM, you should now see:**
```json
{
  "error": "invalid_grant",
  "error_description": "AADSTS501051: Application 'xxx' is not assigned to a role for the application 'api://xxx'...",
  "error_codes": [501051],
  "timestamp": "2025-10-28 20:47:07Z"
}
```

🔒 **Security enforced!** Entra ID is now blocking token requests at the source.

#### Step 3e: Verify Authorized Identity Still Works

Finally, confirm the VM's main identity (with app role) still gets tokens:

```bash
echo "Copy this command and run it on the VM to verify authorized identity still works:"
echo ""
echo "curl -s -H Metadata:true \"http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=api://${APP_ID}&client_id=${IDENTITY_CLIENT_ID}\" | jq -r '.access_token' | head -c 50"
echo ""
echo "Expected: ✅ Token successfully obtained (has app role assignment)"
```

**What happened:**
- Service Principal (Function App API Resource) now requires app role assignment
- ✅ VM (with assigned role): Can get tokens from Entra ID for the API
- ❌ Other identities (no assigned role): **Token request DENIED by Entra ID**
- 🔒 Entra ID now blocks unauthorized token requests at the source

**Result:** Three-layer security:
1. **Entra ID token issuance** - Only assigned identities can get tokens for the API (HARD BLOCK)
2. **Token roles claim** - Tokens include the assigned role
3. **Application layer** - Your code validates token signature, audience, and client ID

**Verification:**
```bash
# Check if assignment is required on the API Resource SP
az ad sp show --id $SP_ID --query "appRoleAssignmentRequired"
# Should return: true

# View all caller identities with role assignments to the API
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_ID}/appRoleAssignedTo" \
  | jq -r '.value[] | "✓ Caller: \(.principalDisplayName) - Role: \(.appRoleId)"'
```

---

## Cleanup

When you're done testing, clean up all resources:

```bash
# Delete the resource group and all resources
az group delete --name $RESOURCE_GROUP --yes --no-wait

echo "✅ Cleanup initiated. Resources will be deleted in the background."
```

---

## Security Best Practices

1. **Network Security**
   - Use private endpoints for Function App if possible
   - Restrict VM NSG to only necessary ports
   - Use Azure Bastion instead of public IP for VM access

2. **Identity Management**
   - Use user-assigned managed identities for better control
   - Regularly review role assignments
   - Use principle of least privilege

3. **Function App Security**
   - Enable Easy Auth / Microsoft Entra ID authentication
   - Use app roles for fine-grained access control
   - Enable Application Insights for monitoring
   - Use HTTPS only

4. **Monitoring**
   - Enable diagnostic logs
   - Set up alerts for authentication failures
   - Monitor unusual access patterns

---

## Summary

You have successfully:

✅ Created a user-assigned managed identity  
✅ Deployed a Linux Ubuntu VM (D2s_v3) with the managed identity  
✅ Created a Python Function App with storage key-less access  
✅ Configured Azure AD App Registration with Application ID URI  
✅ Implemented code-based JWT token validation (no Easy Auth needed)  
✅ Validated tokens with signature verification, expiration, and audience checks  
✅ Tested authentication from the VM with successful 200 response  
✅ Verified unauthorized access is blocked with proper 401/403 responses  

The VM can now securely call the Function App using its managed identity without storing any credentials!

**Key Features:**
- 🔒 **No storage keys** - managed identity for all storage access
- 🔐 **Code-based JWT validation** - full control over token validation logic
- ✅ **Better debugging** - detailed error messages and logging
- 🎯 **Client ID validation** - only specific VM identity allowed
- 📊 **Detailed response** - token info, validation status, and caller details

---

## Additional Resources

- [Azure Managed Identities Documentation](https://docs.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/)
- [Azure Functions Authentication](https://docs.microsoft.com/en-us/azure/app-service/overview-authentication-authorization)
- [Azure Instance Metadata Service](https://docs.microsoft.com/en-us/azure/virtual-machines/linux/instance-metadata-service)
- [Azure RBAC Documentation](https://docs.microsoft.com/en-us/azure/role-based-access-control/)

---

**Last Updated:** October 28, 2025