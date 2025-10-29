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

## Reference  

https://learn.microsoft.com/en-us/security/zero-trust/develop/identity   

https://learn.microsoft.com/en-us/security/zero-trust/develop/identity-non-user-applications     
![alt text](image.png)   
![alt text](image-1.png)   

https://learn.microsoft.com/en-us/security/zero-trust/develop/protect-api  

**Simplified Approach:** This guide uses `.default` scope for authentication, which eliminates the need to define and assign app roles. This provides simpler setup while still maintaining strong security through client ID validation in your code.

## Simplified Authentication: Using .default Scope

Instead of creating app roles and role assignments, you can use the `.default` scope with the App Registration's App ID. This approach:

✅ **Eliminates** the need to define app roles in the App Registration  
✅ **Eliminates** the need to assign roles to the managed identity using Microsoft Graph API  
✅ **Eliminates** the need to enable `appRoleAssignmentRequired`  
✅ **Simplifies** token requests - just use `<APP_ID>/.default` as the scope  
✅ **Maintains** strong security through JWT validation and client ID checking in your code  

### How it works:

**Traditional approach with app roles:**
```bash
# 1. Define app roles in App Registration
# 2. Assign roles to managed identity via Graph API
# 3. Request token with: resource=api://<APP_ID>
# 4. Token includes 'roles' claim
# 5. Validate roles claim in code
```

**Simplified approach with .default:**
```bash
# 1. Create App Registration (no roles needed)
# 2. Request token with: resource=<APP_ID>/.default
# 3. Token has no 'roles' claim (that's OK!)
# 4. Validate client_id in your code instead
```

### Token Request Comparison:

| Approach | Resource/Scope Parameter | Roles Claim in Token | Validation Method |
|----------|-------------------------|---------------------|-------------------|
| **App Roles** | `api://<APP_ID>` | ✅ Yes - `"roles": ["Function.Invoke"]` | Check roles claim |
| **.default Scope** | `<APP_ID>/.default` | ❌ No | Check client_id claim |

Both approaches are secure! The `.default` scope simply moves authorization logic entirely to your application code instead of relying on Entra ID roles.

**📖 For detailed comparison and migration guide, see [SIMPLIFIED-AUTH-GUIDE.md](./SIMPLIFIED-AUTH-GUIDE.md)**

---

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

# Note: With .default scope, you can use either:
# - api://{APP_ID}/.default (standard format)
# - {APP_ID}/.default (shortened format - Azure accepts both)
# We'll use the APP_ID directly for simplicity

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

## Step 8e (OPTIONAL): Create Test Service Principal for Local Testing

If you want to test the Function App from your laptop without VM setup, create a dedicated test service principal. **You'll use this after deploying the function code in Step 9.**

```bash
# Create a test app registration and service principal
TEST_APP_NAME="test-caller-${FUNCTION_APP_NAME}"
TEST_APP_ID=$(az ad app create --display-name $TEST_APP_NAME --query appId -o tsv)

# Create service principal
az ad sp create --id $TEST_APP_ID

# Generate a client secret (password)
TEST_CLIENT_SECRET=$(az ad app credential reset --id $TEST_APP_ID --query password -o tsv)

echo "✅ Test Service Principal Created"
echo "   Test App Name: $TEST_APP_NAME"
echo "   Test App ID (Client ID): $TEST_APP_ID"
echo "   Test Client Secret: $TEST_CLIENT_SECRET"
echo ""
echo "⚠️  IMPORTANT: Save these values! The secret cannot be retrieved later."

# Add test service principal to allowed identities
az functionapp config appsettings set \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --settings TEST_CLIENT_ID=$TEST_APP_ID

echo "✅ Test Service Principal added to allowed identities"
echo ""
echo "📝 Save these for testing after Step 9 (function deployment):"
echo ""
echo "export TEST_APP_ID=\"$TEST_APP_ID\""
echo "export TEST_CLIENT_SECRET=\"$TEST_CLIENT_SECRET\""
echo "export TENANT_ID=\"$TENANT_ID\""
echo "export APP_ID=\"$APP_ID\""
echo "export FUNCTION_APP_URL=\"https://${FUNCTION_APP_NAME}.azurewebsites.net\""
```

---

## Step 9: Deploy Python Function Code with JWT Token Validation

The function code will manually validate JWT tokens and check that requests come from the specific VM managed identity.

### 9.1: Navigate to Function Code Directory

The function code is already prepared in `function-app-code/`.

### 9.2: Function Code Overview

The function code in `function-app-code/function_app.py` implements:

- ✅ **JWT token validation** - Verifies signature using Azure AD's public keys
- ✅ **Audience validation** - Accepts both `api://APP_ID` and `APP_ID` formats (for .default scope compatibility)
- ✅ **Client ID validation** - Only allows the specific VM managed identity
- ✅ **Expiration checking** - Ensures tokens are not expired
- ✅ **Issuer validation** - Confirms tokens are from your Azure AD tenant
- ✅ **Detailed error messages** - Clear responses for debugging

**Key features:**
- No Easy Auth required - all validation in code
- Works with `.default` scope tokens
- Returns detailed caller and token information
- Proper HTTP status codes (401 for auth errors, 403 for forbidden)

#### Why Accept Both Audience Formats?

The function accepts both `api://APP_ID` and `APP_ID` audience formats because **Entra ID handles the audience claim differently** based on how you request the token:

| Token Request Scope | Audience (`aud`) in Token | Reason |
|-------------------|------------------------|---------|
| `api://APP_ID` | `api://APP_ID` | Traditional format - uses full Application ID URI |
| `APP_ID/.default` | `APP_ID` | **Entra ID strips `api://` prefix** when using `.default` scope |


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

### 9.6 (OPTIONAL): Test from Your Laptop with Service Principal

If you created a test service principal in Step 8e, you can now test the deployed function from your laptop:

```bash
# Set your variables (use the values saved from Step 8e)
TEST_APP_ID="<your-test-app-id>"
TEST_CLIENT_SECRET="<your-test-client-secret>"
TENANT_ID="<your-tenant-id>"
APP_ID="<your-api-app-id>"
FUNCTION_APP_URL="https://<your-function-app>.azurewebsites.net"

# Get access token using client credentials flow (no user interaction!)
ACCESS_TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=${TEST_APP_ID}" \
  -d "client_secret=${TEST_CLIENT_SECRET}" \
  -d "scope=${APP_ID}/.default" \
  -d "grant_type=client_credentials" | jq -r '.access_token')

echo "Access Token obtained: ${ACCESS_TOKEN:0:50}..."

# Call the Function App
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  "${FUNCTION_APP_URL}/api/HttpTrigger" | jq

# Expected response will show:
# - "caller_type": "Test service principal"
# - Your test app's client ID
# - Validation showing test client allowed
```

**Benefits of Using Service Principal for Testing:**
- ✅ No browser/interactive login required
- ✅ No consent prompts
- ✅ Test without spinning up the VM
- ✅ Works in CI/CD pipelines
- ✅ Easy to revoke (just delete the app registration)

**Security Note:** Keep the `TEST_CLIENT_SECRET` secure! Treat it like a password.

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

# Use .default scope for simplified authentication (no app roles needed)
# Both formats work: "api://${APP_ID}/.default" or "${APP_ID}/.default"
RESOURCE="${APP_ID}/.default"

echo "=========================================="
echo "VM to Function App Authentication Test"
echo "=========================================="
echo "Function App URL: $FUNCTION_APP_URL"
echo "Resource (App ID): $APP_ID"
echo "Scope: $RESOURCE (.default scope - no app roles needed!)"
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
   - Regularly review and audit identity permissions
   - Use principle of least privilege

3. **Function App Security**
   - Implement JWT validation in code for full control
   - Use HTTPS only
   - Enable Application Insights for monitoring
   - Regularly review and rotate credentials if applicable

4. **Monitoring**
   - Enable diagnostic logs
   - Set up alerts for authentication failures
   - Monitor unusual access patterns
   - Review Function App logs regularly

---

## Summary

You have successfully:

✅ Created a user-assigned managed identity  
✅ Deployed a Linux Ubuntu VM (D2s_v3) with the managed identity  
✅ Created a Python Function App with storage key-less access  
✅ Configured Azure AD App Registration with Application ID URI  
✅ Implemented code-based JWT token validation (no Easy Auth needed)  
✅ Used **`.default` scope for simplified authentication** (no app roles needed!)  
✅ Validated tokens with signature verification, expiration, and audience checks  
✅ Tested authentication from the VM with successful 200 response  
✅ Verified unauthorized access is blocked with proper 401/403 responses  

The VM can now securely call the Function App using its managed identity without storing any credentials!

**Key Features:**
- 🔒 **No storage keys** - managed identity for all storage access
- 🔐 **Code-based JWT validation** - full control over token validation logic
- ✅ **Simplified authentication** - `.default` scope, no app roles configuration
- 🎯 **Client ID validation** - only specific VM identity allowed
- 📊 **Detailed response** - token info, validation status, and caller details
- 🚀 **Easy setup** - fewer steps, no Graph API calls required

---

## Additional Resources

- [Azure Managed Identities Documentation](https://docs.microsoft.com/en-us/azure/active-identity/managed-identities-azure-resources/)
- [Azure Functions Authentication](https://docs.microsoft.com/en-us/azure/app-service/overview-authentication-authorization)
- [Azure Instance Metadata Service](https://docs.microsoft.com/en-us/azure/virtual-machines/linux/instance-metadata-service)
- [Microsoft Identity Platform Documentation](https://docs.microsoft.com/en-us/azure/active-directory/develop/)
- [Microsoft Entra ID - OAuth 2.0 and OpenID Connect Protocols](https://learn.microsoft.com/en-us/entra/identity-platform/v2-protocols-oidc) - Official documentation on token behavior and `.default` scope
- [Microsoft Entra ID - Application ID URI](https://learn.microsoft.com/en-us/entra/identity-platform/security-best-practices-for-app-registration#application-id-uri) - Best practices for configuring Application ID URIs
- [Zero Trust Security](https://learn.microsoft.com/en-us/security/zero-trust/develop/identity)

**📖 For detailed comparison of authentication approaches, see [SIMPLIFIED-AUTH-GUIDE.md](./SIMPLIFIED-AUTH-GUIDE.md)**

---

**Last Updated:** October 29, 2025
