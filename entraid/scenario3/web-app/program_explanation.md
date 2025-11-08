# Step-by-Step Program Explanation: Web App with Managed Identity (Scenario 3)

This document provides a detailed line-by-line explanation of how the web app uses Azure Managed Identity with Federated Credentials instead of client secrets.

---

## Table of Contents
1. [Overview](#overview)
2. [Key Differences from Scenario 2](#key-differences-from-scenario-2)
3. [What is Managed Identity?](#what-is-managed-identity)
4. [What are Federated Credentials?](#what-are-federated-credentials)
5. [Configuration Changes](#configuration-changes)
6. [Modified _build_msal_app Function](#modified-_build_msal_app-function)
7. [Complete Authentication Flow](#complete-authentication-flow)
8. [Security Advantages](#security-advantages)
9. [When to Use This Pattern](#when-to-use-this-pattern)

---

## Overview

**Scenario 3 is identical to Scenario 2 EXCEPT for how it authenticates to Entra ID:**

- **Scenario 2:** Uses CLIENT_SECRET (password) to prove app identity
- **Scenario 3:** Uses **Managed Identity** with **Federated Credentials** (passwordless)

**Everything else is the same:**
- User login flow identical
- API calling identical
- Token acquisition identical
- Only difference: how the app proves its identity to Microsoft

---

## Key Differences from Scenario 2

### Code Changes

Only **ONE function** is different: `_build_msal_app()`

All other code is **100% identical**:
- Routes: `/`, `/login`, `/getAToken`, `/logout`, `/call-api`
- Token caching
- API calling logic
- Session management

### Configuration Changes (app_config.py)

```python
# Web App Client ID
CLIENT_ID = os.getenv("CLIENT_ID", "YOUR_CLIENT_ID")

# Managed Identity Client ID (User-Assigned Managed Identity)
# This is the client ID of the managed identity, NOT the app registration
MANAGED_IDENTITY_CLIENT_ID = os.getenv("MANAGED_IDENTITY_CLIENT_ID", None)

TENANT_ID = os.getenv("TENANT_ID", "YOUR_TENANT_ID")
```

**Changes from Scenario 2:**

❌ **REMOVED:** `CLIENT_SECRET`
- No password needed!
- More secure

✅ **ADDED:** `MANAGED_IDENTITY_CLIENT_ID`
- Client ID of the managed identity resource
- Different from app registration CLIENT_ID

### New Import

```python
from azure.identity import ManagedIdentityCredential
```

- Library for acquiring managed identity tokens
- Part of Azure SDK for Python
- Handles token acquisition from Azure's metadata service

---

## What is Managed Identity?

### Traditional Authentication (Scenario 2)

```
App → "Here's my CLIENT_ID and CLIENT_SECRET" → Microsoft
Microsoft → "Secret matches, here's a token" → App
```

**Problems:**
- Secret must be stored (environment variable, Key Vault, config file)
- Secret can be leaked (logs, source control, memory dumps)
- Secret expires and must be rotated
- Secret can be stolen and used anywhere

### Managed Identity Authentication (Scenario 3)

```
App → "I'm running in Azure, give me identity token" → Azure Metadata Service
Azure → "Here's a token proving you're this managed identity" → App
App → "Here's managed identity token" → Microsoft
Microsoft → "Token valid, here's access token" → App
```

**Advantages:**
- **No secrets to store** - Azure manages everything
- **No secrets to leak** - Nothing sensitive in code/config
- **No rotation needed** - Azure handles it
- **Can't be used outside Azure** - Tokens only work from Azure resources

### Types of Managed Identities

#### System-Assigned Managed Identity
- Tied to specific Azure resource (VM, App Service, Container Instance)
- Created/deleted with the resource
- Can't be shared across resources
- Automatically cleaned up when resource deleted

#### User-Assigned Managed Identity (Used in Scenario 3)
- Independent Azure resource
- Can be assigned to multiple resources
- Persists independently of resources
- More flexible for complex scenarios

**Scenario 3 uses User-Assigned Managed Identity**

---

## What are Federated Credentials?

### The Challenge

You have:
1. **App Registration** in Entra ID (represents your web app)
2. **Managed Identity** in Azure (attached to your Azure resource)

You want:
- Managed Identity to act as the App Registration
- No client secret required

### The Solution: Federated Credentials

**Federated Credential** = Trust relationship between App Registration and Managed Identity

**Setup (in Azure Portal):**
1. Create User-Assigned Managed Identity
2. Assign it to Azure resource (Container App, VM, etc.)
3. In App Registration, add Federated Credential
4. Configure credential to trust the Managed Identity

**Result:**
- Managed Identity can get tokens for the App Registration
- No client secret needed
- App Registration trusts tokens from Managed Identity

### How It Works

1. **App requests token from Azure Metadata Service**
   - Special endpoint available only within Azure
   - `http://169.254.169.254/metadata/identity/oauth2/token`

2. **Azure returns Managed Identity token**
   - Token has audience: `api://AzureADTokenExchange`
   - Proves: "This code is running as managed identity XYZ"

3. **App exchanges MI token for App Registration token**
   - Sends MI token to Entra ID
   - Says: "I'm the managed identity, give me token for App Registration"
   - Entra ID checks federated credential configuration
   - If trust exists, issues token for App Registration

4. **App uses App Registration token**
   - Functions exactly like token from CLIENT_SECRET
   - Can authenticate users, call APIs, etc.

**This is called "Workload Identity Federation"**

---

## Configuration Changes

### Scenario 2 Config

```python
CLIENT_ID = "webapp-guid"
CLIENT_SECRET = "secret-password-string"  # ❌ Secret in config!
TENANT_ID = "tenant-guid"
```

### Scenario 3 Config

```python
CLIENT_ID = "webapp-guid"  # Same app registration
MANAGED_IDENTITY_CLIENT_ID = "managed-identity-guid"  # ✅ No secret!
TENANT_ID = "tenant-guid"
```

**Key points:**

- `CLIENT_ID` - Same app registration as Scenario 2
- `MANAGED_IDENTITY_CLIENT_ID` - NEW: ID of managed identity resource
  - Find in Azure Portal under Managed Identities
  - Different GUID than app registration
- No `CLIENT_SECRET` - That's the whole point!

---

## Modified _build_msal_app Function

This is the **ONLY function that changes** from Scenario 2.

### Old Version (Scenario 2 - Client Secret)

```python
def _build_msal_app(cache=None, authority=None):
    return msal.ConfidentialClientApplication(
        app_config.CLIENT_ID,
        authority=authority or app_config.AUTHORITY,
        client_credential=app_config.CLIENT_SECRET,  # ❌ Static secret
        token_cache=cache
    )
```

### New Version (Scenario 3 - Managed Identity)

```python
def _build_msal_app(cache=None, authority=None):
    """
    Build a ConfidentialClientApplication instance using Managed Identity
    
    Instead of using a client secret, this uses a managed identity credential
    that acquires tokens on behalf of the app registration via federated credentials.
    """
```

#### Step 1: Create Managed Identity Credential

```python
    # Get managed identity credential
    # If MANAGED_IDENTITY_CLIENT_ID is set, use specific managed identity
    # Otherwise, use system-assigned managed identity
    if app_config.MANAGED_IDENTITY_CLIENT_ID:
        credential = ManagedIdentityCredential(
            client_id=app_config.MANAGED_IDENTITY_CLIENT_ID
        )
    else:
        credential = ManagedIdentityCredential()
```

**Line-by-line:**

- `if app_config.MANAGED_IDENTITY_CLIENT_ID:` - Check if user-assigned MI specified
- `credential = ManagedIdentityCredential(client_id=...)` - Create credential for specific MI
  - `client_id` - The managed identity's GUID
  - Tells Azure which MI to use (important if resource has multiple)
- `else: credential = ManagedIdentityCredential()` - Use system-assigned MI
  - No parameters needed
  - Uses the MI automatically attached to the Azure resource

**What is `ManagedIdentityCredential`?**
- Object that knows how to get tokens from Azure Metadata Service
- Handles all the complex details:
  - Finding metadata endpoint
  - Making HTTP requests
  - Parsing responses
  - Caching tokens
  - Retrying on failures

#### Step 2: Define Token Acquisition Function

```python
    # Get access token for the app registration using managed identity
    # The managed identity must have federated credentials configured
    # to impersonate the app registration
    def get_token_for_client():
        """
        Acquire token using managed identity for client credential flow
        The managed identity gets a token to act as the app registration
        """
        # For federated credentials, the audience must be api://AzureADTokenExchange
        # This is the standard audience for workload identity federation
        token_result = credential.get_token(
            "api://AzureADTokenExchange"
        )
        return token_result.token
```

**Line-by-line:**

- `def get_token_for_client():` - Nested function to get client credential
- `credential.get_token("api://AzureADTokenExchange")` - Request MI token

**About `"api://AzureADTokenExchange"`:**
- **Standard audience for federated credentials**
- Not specific to your app
- Microsoft-defined constant
- Tells Azure: "Give me token for workload identity federation"

**What happens internally:**

1. **`credential.get_token()` makes request to Azure Metadata Service:**
   ```
   GET http://169.254.169.254/metadata/identity/oauth2/token
   ?api-version=2018-02-01
   &resource=api://AzureADTokenExchange
   &client_id={MANAGED_IDENTITY_CLIENT_ID}
   ```

2. **Azure Metadata Service responds:**
   ```json
   {
     "access_token": "eyJ0eXAiOiJKV1Q...",
     "expires_in": 3600,
     "token_type": "Bearer"
   }
   ```

3. **Token contains:**
   - Subject: Managed Identity's ID
   - Audience: `api://AzureADTokenExchange`
   - Issuer: Azure AD
   - Expiration: Usually 1 hour

- `return token_result.token` - Return just the token string
  - `token_result` is object with `.token`, `.expires_on`, etc.
  - MSAL only needs the token string

#### Step 3: Create MSAL App with Client Assertion

```python
    return msal.ConfidentialClientApplication(
        app_config.CLIENT_ID,
        authority=authority or app_config.AUTHORITY,
        client_credential={"client_assertion": get_token_for_client},
        token_cache=cache
    )
```

**Line-by-line:**

- `app_config.CLIENT_ID` - App registration ID (same as Scenario 2)
- `authority` - Entra ID endpoint (same as Scenario 2)
- `client_credential={"client_assertion": get_token_for_client}` - **THE KEY DIFFERENCE**

**Client Credential Formats:**

Scenario 2:
```python
client_credential = "static-secret-string"
```

Scenario 3:
```python
client_credential = {"client_assertion": get_token_for_client}
```

**What is "client_assertion"?**
- Alternative to client secret
- Function that returns a JWT token
- MSAL calls this function whenever it needs to authenticate
- Token proves identity via federation instead of secret

**How MSAL uses this:**

1. **User logs in, MSAL needs to exchange auth code for tokens**
2. **MSAL needs to authenticate the app to Entra ID**
3. **MSAL calls `get_token_for_client()`**
4. **Function returns Managed Identity token**
5. **MSAL sends MI token to Entra ID as client credential**
6. **Entra ID validates:**
   - Is token valid? (signature, expiration)
   - Is it from a managed identity?
   - Does federated credential trust this MI?
   - If yes, authenticate app and issue tokens
7. **MSAL receives tokens and continues**

**Why function instead of static string?**
- Managed Identity tokens expire (like access tokens)
- Function called fresh each time
- Always gets current, valid MI token
- MSAL handles all caching and refresh

---

## Complete Authentication Flow

### Initial User Login (Step-by-Step)

1. **User visits home page, clicks "Sign In"**
   - Same as Scenario 2

2. **App redirects to Microsoft login**
   - Same as Scenario 2

3. **User logs in at Microsoft**
   - Same as Scenario 2

4. **Microsoft redirects back with authorization code**
   - Same as Scenario 2

5. **App needs to exchange code for tokens**
   - This is where Scenario 3 differs!

6. **MSAL prepares token exchange request**
   - Needs to authenticate the app
   - Instead of client secret, calls `get_token_for_client()`

7. **`get_token_for_client()` executes:**
   ```python
   credential.get_token("api://AzureADTokenExchange")
   ```

8. **ManagedIdentityCredential contacts Azure Metadata Service:**
   ```
   GET http://169.254.169.254/metadata/identity/oauth2/token
   Headers: Metadata: true
   Params: 
     - resource: api://AzureADTokenExchange
     - client_id: {MANAGED_IDENTITY_CLIENT_ID}
   ```

9. **Azure Metadata Service validates:**
   - Is request from Azure resource? ✓
   - Does resource have this MI assigned? ✓
   - Returns MI token

10. **MI token returned to app:**
    ```json
    {
      "access_token": "eyJ0eXAiOiJKV1Q...",
      "subject": "managed-identity-object-id",
      "audience": "api://AzureADTokenExchange"
    }
    ```

11. **MSAL sends token exchange request to Entra ID:**
    ```
    POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
    Body:
      - grant_type: authorization_code
      - code: {auth_code}
      - client_id: {CLIENT_ID}
      - client_assertion_type: urn:ietf:params:oauth:client-assertion-type:jwt-bearer
      - client_assertion: {MI_TOKEN}
      - redirect_uri: http://localhost:5000/getAToken
    ```

12. **Entra ID validates:**
    - Is authorization code valid? ✓
    - Is client_assertion (MI token) valid? ✓
    - Does app registration have federated credential for this MI? ✓
    - All checks pass!

13. **Entra ID issues tokens:**
    ```json
    {
      "id_token": "eyJ...",
      "access_token": "eyJ...",
      "refresh_token": "0.AX..."
    }
    ```

14. **App stores tokens in session**
   - Same as Scenario 2

15. **User logged in!**
   - Same as Scenario 2

### Calling Protected API

**100% identical to Scenario 2:**
1. Get token from cache with `acquire_token_silent()`
2. Call API with Bearer token
3. Display results

**No difference** - API calling doesn't involve client credentials

### Token Refresh

When access token expires and refresh token used:

1. **MSAL detects expired access token**
2. **MSAL prepares refresh token request**
3. **Needs to authenticate app**
4. **Calls `get_token_for_client()` again**
5. **Gets fresh MI token from Azure**
6. **Sends refresh request with MI token as client credential**
7. **Entra ID issues new access token**
8. **User experience seamless**

---

## Security Advantages

### Scenario 2 (Client Secret) Vulnerabilities

❌ **Secret in environment variables**
- Can be logged accidentally
- Visible in process listings
- Captured in crash dumps

❌ **Secret in source control**
- If accidentally committed
- Visible in Git history forever
- Shared with all developers

❌ **Secret rotation required**
- Manual process
- Downtime if not coordinated
- Easy to forget

❌ **Secret can be extracted**
- From running process
- From configuration files
- From backups

❌ **Secret works anywhere**
- If stolen, can be used from attacker's machine
- Hard to detect unauthorized use

### Scenario 3 (Managed Identity) Security

✅ **No secrets to protect**
- Nothing sensitive to store
- Nothing to leak

✅ **Tokens only work from Azure**
- MI tokens only issued to Azure resources
- Can't use from laptop, attacker's server, etc.
- Automatic IP/resource binding

✅ **No rotation needed**
- Azure manages all credentials
- Transparent updates
- Zero downtime

✅ **Can't extract credentials**
- No secret to extract
- Tokens short-lived
- Automatically refreshed

✅ **Azure monitoring built-in**
- All token requests logged
- Unusual patterns detected
- Integration with Azure Security Center

✅ **Principle of least privilege**
- MI only has permissions it needs
- Can't be used for other resources
- Scoped to specific app registration

---

## When to Use This Pattern

### ✅ Use Managed Identity (Scenario 3) When:

1. **Running in Azure**
   - Azure Container Apps
   - Azure App Service
   - Azure Virtual Machines
   - Azure Container Instances
   - Azure Kubernetes Service (AKS)

2. **Security is critical**
   - Compliance requirements (SOC 2, ISO 27001, etc.)
   - Handling sensitive data
   - High-value targets

3. **Want zero-trust architecture**
   - No long-lived secrets
   - Azure-native security
   - Automated credential management

4. **Multiple environments**
   - Dev, staging, production
   - Each has own MI
   - No secret sharing/rotation across environments

### ❌ Don't Use Managed Identity When:

1. **Running outside Azure**
   - Local development (use client secret)
   - On-premises servers
   - Other cloud providers
   - MI only works in Azure

2. **Need to run locally**
   - Development on laptop
   - Can use DefaultAzureCredential (tries MI, then fallback)
   - Or separate dev configuration with client secret

3. **Simple scenarios**
   - Learning/prototyping
   - Single-tenant applications
   - When client secret acceptable

---

## Local Development Considerations

### Challenge

Managed Identity only works in Azure, but developers work locally.

### Solutions

#### Option 1: Separate Dev Configuration

```python
# Local development
if os.getenv("ENVIRONMENT") == "development":
    client_credential = CLIENT_SECRET
else:
    # Production: use managed identity
    client_credential = {"client_assertion": get_token_for_client}
```

#### Option 2: DefaultAzureCredential

```python
from azure.identity import DefaultAzureCredential

credential = DefaultAzureCredential()
# Tries in order:
# 1. Environment variables (local dev)
# 2. Managed Identity (Azure)
# 3. Visual Studio Code
# 4. Azure CLI
# 5. Azure PowerShell
```

#### Option 3: Azure CLI Authentication

For local dev:
```bash
az login
```

Use `AzureCliCredential` in code:
```python
from azure.identity import AzureCliCredential
credential = AzureCliCredential()
```

---

## Federated Credential Configuration

### Azure Portal Setup

1. **Create User-Assigned Managed Identity**
   - Azure Portal → Managed Identities → Create
   - Name: `my-app-identity`
   - Note the Client ID

2. **Assign MI to Azure Resource**
   - Go to your Container App / VM / App Service
   - Identity → User Assigned → Add
   - Select the managed identity

3. **Configure Federated Credential on App Registration**
   - Azure Portal → App Registrations → Your App
   - Certificates & Secrets → Federated Credentials → Add
   - Federated credential scenario: "Other issuer"
   - Issuer: `https://login.microsoftonline.com/{TENANT_ID}/v2.0`
   - Subject identifier: `{MANAGED_IDENTITY_OBJECT_ID}`
   - Audience: `api://AzureADTokenExchange`
   - Name: `managed-identity-federation`

4. **Update App Configuration**
   ```bash
   MANAGED_IDENTITY_CLIENT_ID="{managed-identity-client-id}"
   ```

### Verification

Test MI token acquisition:
```bash
# From Azure resource (Container App, VM, etc.)
curl -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?\
   api-version=2018-02-01&\
   resource=api://AzureADTokenExchange&\
   client_id={MANAGED_IDENTITY_CLIENT_ID}"
```

Should return:
```json
{
  "access_token": "eyJ...",
  "expires_in": 3599,
  "resource": "api://AzureADTokenExchange",
  "token_type": "Bearer"
}
```

---

## Troubleshooting

### Issue: "ManagedIdentityCredential authentication unavailable"

**Cause:** Not running in Azure, or MI not assigned to resource

**Solutions:**
1. Verify running in Azure Container App/VM/App Service
2. Check MI assigned to resource
3. For local dev, use client secret or Azure CLI auth

### Issue: "Client assertion is invalid"

**Cause:** Federated credential not configured correctly

**Solutions:**
1. Verify federated credential exists on app registration
2. Check subject identifier matches MI's object ID (not client ID!)
3. Verify audience is `api://AzureADTokenExchange`
4. Check issuer format correct

### Issue: "AADSTS700016: Application not found"

**Cause:** CLIENT_ID incorrect or app registration deleted

**Solutions:**
1. Verify CLIENT_ID in config
2. Check app registration exists in Azure Portal
3. Verify in correct tenant

### Issue: MI token acquired but app token fails

**Cause:** Federated credential trust not established

**Solutions:**
1. Wait a few minutes (propagation delay)
2. Verify federated credential saved correctly
3. Check subject identifier is object ID, not client ID
4. Try removing and re-adding federated credential

---

## Summary

**Scenario 3 uses Managed Identity with Federated Credentials for passwordless authentication:**

**Key concepts:**
- **Managed Identity** - Azure-managed identity for resources
- **Federated Credentials** - Trust relationship between MI and app registration
- **Workload Identity Federation** - MI acts as app registration
- **Client Assertion** - MI token used instead of client secret

**How it works:**
1. App requests token from Azure Metadata Service
2. Azure issues MI token (proves running in Azure as specific MI)
3. App sends MI token to Entra ID as client credential
4. Entra ID checks federated credential trust
5. If valid, issues app tokens
6. App functions normally with no secret required

**Benefits:**
- No secrets to manage
- More secure (can't extract/steal credentials)
- No rotation needed
- Tokens only work from Azure
- Azure-native monitoring

**Only code difference from Scenario 2:**
- `_build_msal_app()` uses `client_assertion` instead of `client_secret`
- Everything else identical

**Best for:**
- Production deployments in Azure
- Security-sensitive applications
- Zero-trust architectures
- Compliance requirements
