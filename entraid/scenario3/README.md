# Scenario 3: Web App Calls Protected API (with Managed Identity & Federated Credentials)

This scenario demonstrates a Python web application that signs in users and calls a protected web API on behalf of the signed-in user. Both the web app and API are deployed to Azure Container Apps.

**Key Difference from Scenario 2**: This scenario uses **User-Assigned Managed Identity with Federated Credentials** instead of client secrets for passwordless authentication.

Based on Microsoft's tutorial: [Call an API from a web app](https://learn.microsoft.com/entra/identity-platform/tutorial-web-app-python-call-api-overview)

## Architecture

**Components:**
- **Web Application**: Flask app that authenticates users and acquires access tokens using managed identity
- **Protected API**: Flask API that validates access tokens and returns claims
- **Entra ID**: Two app registrations (API as resource, Web App as client with federated credentials)
- **User-Assigned Managed Identity**: Azure identity for passwordless authentication
- **Azure Container Apps**: Cloud hosting for both applications

**Authentication Flow:**
1. User signs into Web App using Entra ID (OpenID Connect)
2. Web App uses managed identity to acquire access token (no client secret!)
3. Managed identity presents its token to get app registration token via federated credential trust
4. Web App calls Protected API with access token in Authorization header
5. API validates the JWT token and returns user claims

**Security Improvement:**
- ❌ **Scenario 2**: Client secret stored in environment variables
- ✅ **Scenario 3**: No secrets - managed identity with federated credentials
- ✅ Zero secret management overhead
- ✅ Automatic credential rotation by Azure

## Prerequisites

- Azure subscription with permissions to create app registrations
- Azure CLI installed and authenticated (`az login`)
- Python 3.7+ (for local testing)
- Docker (for containerization)

## Quick Start

### Deploy to Azure Container Apps (Recommended)

**Note**: This scenario requires Azure deployment as managed identities only work in Azure environments.

1. **Set up Entra ID app registrations:**
```bash
cd entraid/scenario3
source ./setup-entraid.sh
```

This creates:
- API app registration with exposed OAuth2 scope `api://{appid}/access_as_user`
- Web app registration with granted API permission
- **No client secret created** (uses managed identity instead)
- Exports environment variables automatically

2. **Deploy to Azure:**
```bash
./deploy-to-azure.sh
```

This will:
- Create resource group and Azure Container Registry
- **Create User-Assigned Managed Identity**
- Build and push Docker images for both apps
- Create Container Apps Environment
- Deploy API and Web App containers
- **Assign managed identity to web app**
- **PAUSE for manual step**: Configure federated credential via Azure Portal
- Update Entra ID redirect URI for production URL
- Output the public URLs for both apps

3. **During deployment - Manual Step (Step 9):**
When the script pauses, follow the portal instructions to:
- Navigate to your web app registration in Azure Portal
- Add a federated credential for the managed identity
- This establishes the trust relationship for passwordless authentication

4. **Access your apps:**
- Web App: `https://<web-app-fqdn>` (shown in script output)
- API: `https://<api-fqdn>` (shown in script output)

### Local Testing Not Supported

Unlike Scenario 2, local testing is not supported because:
- Managed identities only work within Azure infrastructure
- Federated credentials require Azure-issued managed identity tokens
- For local development, use Scenario 2 (with client secrets)

## Project Structure

```
scenario3/
├── api/
│   ├── app.py              # Protected API with JWT validation
│   ├── requirements.txt    # API dependencies (same as scenario2)
│   └── Dockerfile          # API container image
├── web-app/
│   ├── app.py              # Web app with MSAL + Managed Identity integration
│   ├── app_config.py       # Configuration (NO CLIENT_SECRET, uses MANAGED_IDENTITY_CLIENT_ID)
│   ├── requirements.txt    # Web app dependencies (includes azure-identity)
│   ├── templates/          # HTML templates
│   └── Dockerfile          # Web app container image
├── setup-entraid.sh        # Creates app registrations (no client secret)
├── deploy-to-azure.sh      # Deploys to Azure with managed identity
├── cleanup.sh              # Removes all Azure and Entra ID resources
└── README.md               # This file
```

**Key Code Changes from Scenario 2:**

1. **web-app/app_config.py:**
```python
# Scenario 2: Uses client secret
CLIENT_SECRET = os.getenv("CLIENT_SECRET")

# Scenario 3: Uses managed identity client ID
MANAGED_IDENTITY_CLIENT_ID = os.getenv("MANAGED_IDENTITY_CLIENT_ID")
```

2. **web-app/app.py:**
```python
# Scenario 2: Client secret for authentication
from msal import ConfidentialClientApplication

app = ConfidentialClientApplication(
    client_id,
    client_credential=CLIENT_SECRET,  # Secret in environment variable
    authority=authority
)

# Scenario 3: Managed identity with federated credentials
from azure.identity import ManagedIdentityCredential
from msal import ConfidentialClientApplication

credential = ManagedIdentityCredential(
    client_id=MANAGED_IDENTITY_CLIENT_ID
)

def get_token_for_client():
    # Managed identity gets token with audience api://AzureADTokenExchange
    token_result = credential.get_token("api://AzureADTokenExchange")
    return token_result.token

app = ConfidentialClientApplication(
    client_id,
    client_credential={"client_assertion": get_token_for_client},  # No secret!
    authority=authority
)
```

3. **web-app/requirements.txt:**
```
# Scenario 3 adds:
azure-identity>=1.15.0  # For ManagedIdentityCredential
```
│   ├── app_config.py       # Configuration using env vars
│   ├── requirements.txt    # Web app dependencies
│   ├── Dockerfile          # Web app container image
│   └── templates/
│       ├── index.html      # Home page
│       ├── login.html      # Login page
│       ├── display.html    # User info display
│       └── api_response.html  # API response display
├── setup-entraid.sh        # Creates app registrations
├── deploy-to-azure.sh      # Deploys to Container Apps
├── cleanup.sh              # Removes all resources
└── README.md               # This file
```

## Configuration

### Environment Variables

**API (`api/app.py`):**
- `TENANT_ID`: Your Azure AD tenant ID
- `API_CLIENT_ID`: Application ID of the API app registration
- `PORT`: Port number (default: 5001)

**Web App (`web-app/app_config.py`):**
- `CLIENT_ID`: Application ID of the web app registration
- `CLIENT_SECRET`: Client secret for the web app
- `TENANT_ID`: Your Azure AD tenant ID
- `API_CLIENT_ID`: Application ID of the API (for scope construction)
- `API_ENDPOINT`: Full URL to the API endpoint (e.g., `http://localhost:5001/api/claims`)
- `PORT`: Port number (default: 5000)

These are automatically set by `setup-entraid.sh` for local testing.

### API Scope

The API exposes a delegated permission scope:
- **Scope**: `api://{API_CLIENT_ID}/access_as_user`
- **Type**: Delegated (requires signed-in user)
- **Admin Consent**: Not required (user-level consent)

The web app requests this scope when acquiring access tokens.

## How It Works

### 1. API Authentication

The API uses JWT token validation:

```python
@require_auth
def claims():
    # Decorated endpoints validate the access token
    # Token must:
    # - Be a valid JWT signed by Microsoft
    # - Have correct audience (API_CLIENT_ID)
    # - Not be expired
    # - Have correct issuer (tenant-specific)
    return jsonify(g.user_claims)
```

**Token Validation Process:**
1. Extract Bearer token from Authorization header
2. Fetch Microsoft's public signing keys (JWKS)
3. Decode and validate JWT signature
4. Verify audience, issuer, and expiration
5. Store validated claims in `g.user_claims`

### 2. Web App Token Acquisition

The web app acquires tokens with API scope:

```python
# Build scope with API's Application ID URI
scope = [f"api://{app_config.API_CLIENT_ID}/access_as_user"]

# Acquire token for the API
result = msal_app.acquire_token_silent(scope, account=account)
if not result:
    result = msal_app.acquire_token_by_authorization_code(...)
```

**Token Flow:**
1. User signs in → Web app gets ID token
2. User clicks "Call API" → Web app requests access token with API scope
3. Entra ID checks if permission is granted → Issues access token
4. Web app calls API with `Authorization: Bearer {access_token}`
5. API validates token and returns claims

### 3. OAuth 2.0 Delegated Permissions

The setup script configures delegated permissions:

```bash
# API exposes scope
az ad app update --id $API_APP_ID --identifier-uris "api://$API_APP_ID"
# Creates scope: api://{API_APP_ID}/access_as_user

# Web app requests permission
az ad app permission add \
    --id $WEB_CLIENT_ID \
    --api $API_APP_ID \
    --api-permissions $SCOPE_ID=Scope  # Delegated permission
```

This allows the web app to act on behalf of the signed-in user.

## Testing

### Local Testing Endpoints

**Web App (http://localhost:5000):**
- `/` - Home page
- `/login` - Initiate sign-in
- `/getAToken` - OAuth callback
- `/call-api` - Acquire token and call API
- `/logout` - Sign out

**API (http://localhost:5001):**
- `/health` - Health check (no auth required)
- `/api/claims` - Returns token claims (requires valid access token)

### Manual API Testing

You can test the API directly with curl:

```bash
# Get an access token (sign in via web app first, then check browser dev tools)
TOKEN="<access_token_from_browser>"

# Call the API
curl -H "Authorization: Bearer $TOKEN" http://localhost:5001/api/claims
```

### View Container App Logs

After deployment:

```bash
# API logs
az containerapp logs show --name api-app --resource-group rg-webapp-calls-api --follow

# Web app logs
az containerapp logs show --name web-app --resource-group rg-webapp-calls-api --follow
```

## Cleanup

### Delete Entra ID Resources Only

```bash
./cleanup.sh
```

Removes:
- API app registration
- Web app registration
- Environment variables

### Delete All Azure Resources

```bash
az group delete --name rg-webapp-calls-api --yes
```

Removes:
- Container Apps (API and Web App)
- Container Apps Environment
- Azure Container Registry
- All associated resources

Or run `./cleanup.sh` and confirm resource group deletion when prompted.

## Troubleshooting

### "Invalid redirect URI"
**Solution:** Ensure redirect URI is registered in Entra ID. For local testing, use `http://localhost:5000/getAToken`. The deployment script automatically adds the production URL.

### "Token validation failed"
**Causes:**
- API_CLIENT_ID mismatch (token audience doesn't match API's client ID)
- Expired token
- Token signed for different tenant

**Solution:** Check environment variables are correct. Ensure `API_CLIENT_ID` in web app matches the API's application ID.

### "Permission not granted"
**Solution:** Run the setup script again, which attempts admin consent: `source ./setup-entraid.sh`

### Container Apps deployment fails
**Causes:**
- Container registry name already taken (must be globally unique)
- Insufficient permissions to create resources

**Solution:** Edit `deploy-to-azure.sh` and change `ACR_NAME` to something unique, or specify a different resource group name.

### API returns 401 Unauthorized
**Debug Steps:**
1. Check API logs: `docker logs <container-id>` or use `az containerapp logs`
2. Verify `TENANT_ID` and `API_CLIENT_ID` environment variables are set correctly in the API container
3. Test token manually by decoding it at https://jwt.ms - verify audience matches API_CLIENT_ID

## Security Considerations

- **Client Secret**: Stored as environment variable in Container Apps (secure configuration). Never commit to git.
- **Token Validation**: API validates every request, ensuring tokens are signed by Microsoft and not expired.
- **HTTPS**: Container Apps provides HTTPS by default for external ingress.
- **Scope Limitation**: Web app only requests `access_as_user` scope - follows principle of least privilege.
- **Session Security**: Web app uses server-side sessions with secure cookies.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                           User's Browser                            │
└────────────┬──────────────────────────────────────────┬─────────────┘
             │                                           │
             │ 1. Sign In                                │ 3. Call API (UI click)
             │                                           │
             ▼                                           ▼
┌─────────────────────────────┐              ┌──────────────────────────┐
│     Web Application         │              │                          │
│  (Flask + MSAL Python)      │              │   Protected API          │
│                             │              │   (Flask + JWT)          │
│  - User authentication      │  4. HTTP     │                          │
│  - Token acquisition        │────GET────▶  │  - Token validation      │
│  - API calls                │  Bearer      │  - Claims extraction     │
│                             │  Token       │                          │
└──────────┬──────────────────┘              └────────┬─────────────────┘
           │                                          │
           │ 2. Auth Code Flow                        │ 5. Validate Token
           │                                          │
           ▼                                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        Microsoft Entra ID                           │
│                                                                     │
│  ┌──────────────────────────┐      ┌──────────────────────────┐   │
│  │  Web App Registration    │      │   API Registration       │   │
│  │  - Client ID/Secret      │      │   - Exposed Scope        │   │
│  │  - Redirect URI          │      │   - Application ID URI   │   │
│  │  - API Permission        │      │   api://{appid}/...      │   │
│  └──────────────────────────┘      └──────────────────────────┘   │
│                                                                     │
│  Issues:                                                            │
│  - ID Token (user identity)                                         │
│  - Access Token (api://{appid}/access_as_user scope)                │
└─────────────────────────────────────────────────────────────────────┘
```

**Flow Details:**
1. User clicks "Sign In" → Web app redirects to Entra ID
2. User authenticates → Entra ID returns authorization code
3. Web app exchanges code for tokens (ID token + refresh token)
4. User clicks "Call API" → Web app acquires access token with API scope
5. Web app sends `GET /api/claims` with `Authorization: Bearer {token}`
6. API fetches Microsoft's public keys, validates JWT signature
7. API verifies audience, issuer, expiration
8. API returns claims from validated token
9. Web app displays response to user

## Appendix

### A. Token Exchange Flow - Detailed

#### Initial Sign-In Flow
```
User Browser          Web App Server           Entra ID
     │                      │                      │
     │─[1] Click Sign In──→ │                      │
     │                      │                      │
     │ ←[2] Redirect────────┤                      │
     │  to login.microsoft  │                      │
     │                      │                      │
     │─[3] User authenticates─────────────────────→│
     │  (username/password) │                      │
     │                      │                      │
     │ ←[4] Redirect with auth code────────────────┤
     │  http://webapp/getAToken?code=ABC123        │
     │                      │                      │
     │─[5] Browser hits──→  │                      │
     │  callback endpoint   │                      │
     │                      │                      │
     │                      │─[6] POST /token ────→│
     │                      │  client_id={ID}      │
     │                      │  client_secret={SEC} │
     │                      │  code=ABC123         │
     │                      │                      │
     │                      │ ←[7] Tokens ─────────┤
     │                      │  {id_token,          │
     │                      │   refresh_token}     │
     │                      │                      │
     │                      │ [8] Store tokens     │
     │                      │  in MSAL cache       │
     │                      │                      │
     │ ←[9] User signed in──┤                      │
```

#### API Call Flow (Silent Token Acquisition)
```
User Browser          Web App Server           Entra ID              Protected API
     │                      │                      │                      │
     │─[1] Click Call API─→│                      │                      │
     │                      │                      │                      │
     │                      │ [2] Check cache:     │                      │
     │                      │  No access token     │                      │
     │                      │  for API scope       │                      │
     │                      │                      │                      │
     │                      │─[3] POST /token ────→│                      │
     │                      │  client_id={ID}      │                      │
     │                      │  client_secret={SEC} │                      │
     │                      │  refresh_token={RT}  │                      │
     │                      │  scope=api://...     │                      │
     │                      │                      │                      │
     │                      │                      │ [4] Validate:        │
     │                      │                      │  ✓ Client creds      │
     │                      │                      │  ✓ Refresh token     │
     │                      │                      │  ✓ Scope allowed     │
     │                      │                      │                      │
     │                      │ ←[5] Access Token───┤                      │
     │                      │  {access_token,      │                      │
     │                      │   new_refresh_token} │                      │
     │                      │                      │                      │
     │                      │ [6] Cache token      │                      │
     │                      │                      │                      │
     │                      │─[7] GET /api/claims ─────────────────────→ │
     │                      │  Authorization:      │                      │
     │                      │  Bearer {token}      │                      │
     │                      │                      │                      │
     │                      │                      │      [8] Validate:   │
     │                      │                      │       ✓ Signature    │
     │                      │                      │       ✓ Audience     │
     │                      │                      │       ✓ Issuer       │
     │                      │                      │       ✓ Expiration   │
     │                      │                      │                      │
     │                      │ ←[9] Return claims ──────────────────────── │
     │                      │  {user_claims}       │                      │
     │                      │                      │                      │
     │ ←[10] Display────────┤                      │                      │
     │  claims to user      │                      │                      │
```

### B. Security Flow - Client Secret Authentication

#### Where Client Secret Comes From
```
1. Setup Script (setup-entraid.sh)
   │
   ├─→ az ad app credential reset
   │   Creates secret in Entra ID
   │   Returns: "dR8Q~abc123xyz..."
   │
   ├─→ export CLIENT_SECRET="dR8Q~abc123xyz..."
   │   Stored in shell environment
   │
   └─→ User runs: source ./setup-entraid.sh
```

#### How Secret Reaches Azure Container Apps
```
2. Local Deployment (deploy-to-azure.sh)
   │
   ├─→ Shell has: CLIENT_SECRET="dR8Q~abc123xyz..."
   │
   ├─→ az containerapp create --env-vars \
   │     "CLIENT_SECRET=$CLIENT_SECRET"
   │   
   │   Bash expands $CLIENT_SECRET
   │   Sends to Azure via API call
   │
   └─→ Azure Container Apps Configuration
       Stores as encrypted environment variable
```

#### How Python Code Uses Secret
```
3. Container Runtime
   │
   ├─→ Azure starts container with env vars:
   │   CLIENT_SECRET=dR8Q~abc123xyz...
   │
   ├─→ Python process starts:
   │   $ python app.py
   │
   ├─→ app_config.py executes:
   │   CLIENT_SECRET = os.getenv("CLIENT_SECRET")
   │   Returns: "dR8Q~abc123xyz..."
   │
   └─→ MSAL uses it:
       msal.ConfidentialClientApplication(
         client_id=CLIENT_ID,
         client_credential=CLIENT_SECRET
       )
```

#### Client Secret in Token Exchange
```
4. Authentication to Entra ID

Web App                              Entra ID
   │                                    │
   │──[Token Request]──────────────────→│
   │  POST /oauth2/v2.0/token           │
   │                                    │
   │  Headers:                          │
   │    Content-Type: application/      │
   │      x-www-form-urlencoded         │
   │                                    │
   │  Body:                             │
   │    client_id=a1b2c3d4-...          │
   │    client_secret=dR8Q~abc123...    │ ← SECRET PROVES IDENTITY
   │    code=ABC123 (or refresh_token)  │
   │    grant_type=authorization_code   │
   │    redirect_uri=...                │
   │                                    │
   │                                    │ [Entra ID Validates]
   │                                    │  ✓ Client ID exists
   │                                    │  ✓ Secret matches stored value
   │                                    │  ✓ Code/refresh token valid
   │                                    │  ✓ Redirect URI registered
   │                                    │
   │  ←[Token Response]─────────────────┤
   │    {                               │
   │      "access_token": "eyJ...",     │
   │      "id_token": "eyJ...",         │
   │      "refresh_token": "0.AXo...",  │
   │      "token_type": "Bearer",       │
   │      "expires_in": 3599            │
   │    }                               │
```

### C. Security Considerations

#### Secret Storage
- ✅ **Never in Git**: `.gitignore` excludes any files with secrets
- ✅ **Not in Docker Image**: Secret added at runtime, not baked into image
- ✅ **Encrypted in Azure**: Container Apps stores secrets encrypted at rest
- ✅ **Process Isolation**: Only container process can access environment variables
- ✅ **Never in Browser**: Client secret only used in server-to-server calls

#### Token Security
- ✅ **Short-lived Access Tokens**: Typically 1 hour expiration
- ✅ **Refresh Token Rotation**: New refresh token issued with each use
- ✅ **Scope Limitation**: Access token only valid for specific API (`api://{appid}`)
- ✅ **Audience Validation**: API verifies token audience matches its client ID
- ✅ **Signature Validation**: API verifies token signed by Microsoft's private key
- ✅ **HTTPS Only**: All token exchanges encrypted in transit

#### Why Confidential Client?
```
┌──────────────────────────────────────────────────────────────┐
│  Public Client (Mobile/SPA)                                  │
├──────────────────────────────────────────────────────────────┤
│  ❌ Cannot securely store secrets                            │
│  ❌ Code runs in user's device/browser                       │
│  ✅ Uses PKCE (Proof Key for Code Exchange) instead          │
│  ✅ Suitable for: Mobile apps, Single Page Apps              │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  Confidential Client (Server-side Web App)                   │
├──────────────────────────────────────────────────────────────┤
│  ✅ Can securely store client secret on server               │
│  ✅ Secret never exposed to browser or network               │
│  ✅ Proves app identity to Entra ID                          │
│  ✅ Enables silent token refresh without user interaction    │
│  ✅ Suitable for: Server-side web apps, APIs, daemons        │
└──────────────────────────────────────────────────────────────┘
```

## References

- [Microsoft Tutorial: Call an API from a Python web app](https://learn.microsoft.com/entra/identity-platform/tutorial-web-app-python-call-api-overview)
- [Workload Identity Federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation)
- [Managed Identities for Azure Resources](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview)
- [MSAL Python Documentation](https://msal-python.readthedocs.io/)
- [Azure Container Apps Documentation](https://learn.microsoft.com/azure/container-apps/)

---

## Appendix

### A. Architecture Comparison: Scenario 2 vs Scenario 3

#### Scenario 2: Traditional Client Secret Authentication

```
┌─────────────────────────────────────────────────────────────────────┐
│                         AZURE DEPLOYMENT                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌───────────────────────────────────────────────────────┐         │
│  │  Container Apps Environment                           │         │
│  │  ┌─────────────────────┐   ┌──────────────────────┐  │         │
│  │  │   Web App Container │   │   API Container      │  │         │
│  │  │                     │   │                      │  │         │
│  │  │  Environment Vars:  │   │  JWT Validation      │  │         │
│  │  │  ├─ CLIENT_ID       │   │  ├─ TENANT_ID        │  │         │
│  │  │  ├─ CLIENT_SECRET ⚠ │   │  └─ API_CLIENT_ID    │  │         │
│  │  │  ├─ TENANT_ID       │   │                      │  │         │
│  │  │  └─ API_CLIENT_ID   │   │                      │  │         │
│  │  └─────────────────────┘   └──────────────────────┘  │         │
│  └───────────────────────────────────────────────────────┘         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
         │                                           │
         │ Uses CLIENT_SECRET                        │ Validates Token
         │ to get tokens                             │
         ▼                                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         ENTRA ID (Azure AD)                         │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────┐   ┌───────────────────────────────┐  │
│  │  Web App Registration    │   │  API App Registration         │  │
│  │  ┌────────────────────┐  │   │  ┌─────────────────────────┐ │  │
│  │  │ Client Secret ⚠   │  │   │  │ Exposed Scope:          │ │  │
│  │  │ (Secret Value)     │  │   │  │ access_as_user          │ │  │
│  │  └────────────────────┘  │   │  └─────────────────────────┘ │  │
│  │  ┌────────────────────┐  │   └───────────────────────────────┘  │
│  │  │ API Permissions    │  │                                       │
│  │  │ access_as_user     │  │                                       │
│  │  └────────────────────┘  │                                       │
│  └──────────────────────────┘                                       │
└─────────────────────────────────────────────────────────────────────┘

⚠ Security Concerns with Client Secret:
  - Secret must be stored in environment variables
  - Secret transmitted during deployment
  - Manual rotation required before expiration
  - Risk of accidental exposure (logs, config files)
  - Must be managed in CI/CD pipelines
```

#### Scenario 3: Managed Identity with Federated Credentials

```
┌─────────────────────────────────────────────────────────────────────┐
│                         AZURE DEPLOYMENT                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌───────────────────────────────────────────────────────────┐     │
│  │  Container Apps Environment                               │     │
│  │  ┌─────────────────────┐   ┌──────────────────────┐      │     │
│  │  │   Web App Container │   │   API Container      │      │     │
│  │  │                     │   │                      │      │     │
│  │  │  Environment Vars:  │   │  JWT Validation      │      │     │
│  │  │  ├─ CLIENT_ID       │   │  ├─ TENANT_ID        │      │     │
│  │  │  ├─ MANAGED_ID ✓    │   │  └─ API_CLIENT_ID    │      │     │
│  │  │  ├─ TENANT_ID       │   │                      │      │     │
│  │  │  └─ API_CLIENT_ID   │   │                      │      │     │
│  │  │                     │   │                      │      │     │
│  │  │  Assigned Identity: │   │                      │      │     │
│  │  │  [Managed ID] ✓    │   │                      │      │     │
│  │  └─────────────────────┘   └──────────────────────┘      │     │
│  └───────────────────────────────────────────────────────────┘     │
│            │                                                        │
│            │ Uses Managed Identity                                 │
│            ▼                                                        │
│  ┌─────────────────────────────────┐                               │
│  │  User-Assigned Managed Identity │                               │
│  │  ├─ Client ID                   │                               │
│  │  ├─ Principal ID                │                               │
│  │  └─ Azure-managed credentials ✓ │                               │
│  └─────────────────────────────────┘                               │
│            │                                                        │
└────────────┼────────────────────────────────────────────────────────┘
             │
             │ Presents MI token with
             │ aud: api://AzureADTokenExchange
             ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         ENTRA ID (Azure AD)                         │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────┐   ┌───────────────────────────────┐  │
│  │  Web App Registration    │   │  API App Registration         │  │
│  │  ┌────────────────────┐  │   │  ┌─────────────────────────┐ │  │
│  │  │ Federated Creds ✓ │  │   │  │ Exposed Scope:          │ │  │
│  │  │ ├─ Issuer:         │  │   │  │ access_as_user          │ │  │
│  │  │ │  sts.windows.net │  │   │  └─────────────────────────┘ │  │
│  │  │ ├─ Subject:        │  │   └───────────────────────────────┘  │
│  │  │ │  <MI Client ID>  │  │                                       │
│  │  │ └─ Audience:       │  │                                       │
│  │  │    api://Azure...  │  │                                       │
│  │  └────────────────────┘  │                                       │
│  │  ┌────────────────────┐  │                                       │
│  │  │ API Permissions    │  │                                       │
│  │  │ access_as_user     │  │                                       │
│  │  └────────────────────┘  │                                       │
│  └──────────────────────────┘                                       │
│             │                                                        │
│             │ Trust relationship established                        │
│             │ "I trust MI xyz to act as this app"                  │
│             ▼                                                        │
│         Issues token for                                            │
│         app registration                                            │
└─────────────────────────────────────────────────────────────────────┘

✓ Security Benefits with Managed Identity:
  - Zero secrets stored anywhere
  - Azure automatically manages credentials
  - Automatic rotation (no expiration concerns)
  - Cannot be accidentally exposed
  - Built-in audit trail in Azure Activity Log
  - Follows principle of least privilege
```

### B. Security Flow Comparison

#### Scenario 2: Client Secret Flow

```
INITIAL DEPLOYMENT
════════════════════════════════════════════════════════════════

1. Developer creates client secret in Azure Portal
   └─> Secret value displayed ONCE: "xYz123..."

2. Developer adds secret to deployment script
   └─> deploy-to-azure.sh contains: CLIENT_SECRET="xYz123..."
       OR stored in CI/CD pipeline secrets

3. Deployment script runs
   └─> az containerapp create \
         --env-vars "CLIENT_SECRET=xYz123..." ⚠

4. Secret stored in Container App environment
   └─> Encrypted at rest in Azure
   └─> Accessible to container process

SECURITY CONCERNS:
─────────────────
⚠ Secret in deployment scripts (version control risk)
⚠ Secret in CI/CD pipeline configuration
⚠ Secret in environment variables
⚠ Must manually rotate before expiration (24 months max)
⚠ Old secret still valid during rotation period
⚠ Risk of exposure in logs or error messages


RUNTIME: Token Acquisition
════════════════════════════════════════════════════════════════

┌──────────┐                                    ┌──────────┐
│ Web App  │                                    │ Entra ID │
└────┬─────┘                                    └────┬─────┘
     │                                                │
     │ 1. User authorization code received           │
     │                                                │
     │ 2. Exchange code for token                    │
     │    POST /oauth2/v2.0/token                   │
     │    ────────────────────────────────────────>  │
     │    Body:                                      │
     │      code: "abc123..."                        │
     │      client_id: "08ffdf6b..."                 │
     │      client_secret: "xYz123..." ⚠            │
     │      redirect_uri: "https://..."              │
     │                                                │
     │                          3. Validates secret  │
     │                             Checks if secret  │
     │                             matches app reg   │
     │                                                │
     │ 4. Returns tokens                             │
     │  <────────────────────────────────────────    │
     │    {                                          │
     │      "access_token": "eyJ...",                │
     │      "refresh_token": "0.AXo...",             │
     │      "id_token": "eyJ..."                     │
     │    }                                          │
     │                                                │
     │ 5. Silent token refresh (later)               │
     │    POST /oauth2/v2.0/token                   │
     │    ────────────────────────────────────────>  │
     │    Body:                                      │
     │      grant_type: "refresh_token"              │
     │      refresh_token: "0.AXo..."                │
     │      client_id: "08ffdf6b..."                 │
     │      client_secret: "xYz123..." ⚠            │
     │                                                │
     │  <────────────────────────────────────────    │
     │    (new tokens)                               │
     │                                                │

EVERY TOKEN REQUEST TRANSMITS THE SECRET ⚠
```

#### Scenario 3: Federated Credential Flow

```
INITIAL DEPLOYMENT
════════════════════════════════════════════════════════════════

1. Deployment script creates User-Assigned Managed Identity
   └─> Azure automatically generates credentials
   └─> NO secrets created or stored ✓

2. Managed Identity assigned to Container App
   └─> az containerapp create --user-assigned <MI-resource-id>
   └─> MI Client ID passed as environment variable
   └─> NO secret transmission ✓

3. Federated credential configured in portal
   └─> Establishes trust: "App registration trusts MI xyz"
   └─> Configuration stored in Entra ID
   └─> NO secrets involved ✓

4. Container starts with managed identity
   └─> Azure Instance Metadata Service provides MI tokens
   └─> Automatic credential rotation by Azure ✓

SECURITY BENEFITS:
──────────────────
✓ Zero secrets created
✓ Zero secrets stored
✓ Zero secrets transmitted
✓ Automatic rotation by Azure
✓ Cannot be accidentally exposed
✓ Audit trail in Azure Activity Log


RUNTIME: Token Acquisition with Federated Credentials
════════════════════════════════════════════════════════════════

┌──────────┐         ┌───────────┐         ┌──────────┐
│ Web App  │         │ Managed   │         │ Entra ID │
│ Container│         │ Identity  │         │          │
└────┬─────┘         └─────┬─────┘         └────┬─────┘
     │                     │                     │
     │ 1. User authorization code received       │
     │                     │                     │
     │ 2. Need token for app registration        │
     │    credential.get_token(                  │
     │      "api://AzureADTokenExchange"         │
     │    )                │                     │
     │ ─────────────────> │                     │
     │                     │                     │
     │                     │ 3. Get MI token from IMDS
     │                     │    (Azure Infrastructure)
     │                     │    No secret needed ✓
     │                     │                     │
     │                     │ 4. Present MI token │
     │                     │    POST /oauth2/v2.0/token
     │                     │ ──────────────────> │
     │                     │    Body:             │
     │                     │      grant_type:     │
     │                     │        "client_credentials"
     │                     │      client_assertion_type:
     │                     │        "urn:ietf:params:oauth:
     │                     │         client-assertion-type:
     │                     │         jwt-bearer"
     │                     │      client_assertion:
     │                     │        "eyJ..." (MI token) ✓
     │                     │      scope: "api://..."
     │                     │                     │
     │                     │         5. Validates MI token:
     │                     │            - Signature valid?
     │                     │            - Issuer matches federated cred?
     │                     │            - Subject matches MI client ID?
     │                     │            - Audience correct?
     │                     │                     │
     │                     │         6. Checks federated credential:
     │                     │            "Does app registration trust
     │                     │             this managed identity?"
     │                     │            YES ✓
     │                     │                     │
     │                     │ 7. Issues app token │
     │                     │ <────────────────── │
     │ 8. Receive token    │    {                │
     │ <─────────────────  │      "access_token"  │
     │    return token     │    }                │
     │                     │                     │
     │ 9. Exchange auth code for user tokens     │
     │    POST /oauth2/v2.0/token               │
     │    ──────────────────────────────────────> │
     │    Body:                                  │
     │      code: "abc123..."                    │
     │      client_id: "08ffdf6b..."             │
     │      client_assertion_type: "jwt-bearer"  │
     │      client_assertion: <MI-derived token> ✓
     │      redirect_uri: "https://..."          │
     │                                            │
     │ 10. Returns user tokens                   │
     │  <──────────────────────────────────────  │
     │    {                                      │
     │      "access_token": "eyJ...",            │
     │      "refresh_token": "0.AXo...",         │
     │      "id_token": "eyJ..."                 │
     │    }                                      │
     │                                            │

NO SECRETS TRANSMITTED - ONLY AZURE-ISSUED TOKENS ✓

KEY SECURITY IMPROVEMENTS:
──────────────────────────
✓ Managed Identity token from Azure IMDS (not a secret)
✓ Token validates MI is running in authorized Azure resource
✓ Federated credential establishes trust without secrets
✓ All tokens short-lived and auto-rotated
✓ Zero secret management overhead
```

### C. Federated Credential Trust Relationship

```
WHAT IS A FEDERATED CREDENTIAL?
═══════════════════════════════════════════════════════════════

A federated credential creates a trust relationship that says:

  "Application X trusts Identity Provider Y to authenticate
   Subject Z, when the token has Audience A"

In Scenario 3:
  Application X = Web App Registration (CLIENT_ID)
  Identity Provider Y = Azure AD (https://sts.windows.net/{tenant}/)
  Subject Z = Managed Identity (Client ID)
  Audience A = api://AzureADTokenExchange


CONFIGURATION IN AZURE PORTAL:
═══════════════════════════════════════════════════════════════

App Registration: Web App Calls API Demo
└─> Certificates & secrets
    └─> Federated credentials
        └─> fedcred-webapp-mi
            ├─ Scenario: Managed Identity
            ├─ Subscription: <your-subscription>
            ├─ Managed Identity: mi-webapp-federated
            ├─ Name: fedcred-webapp-mi
            └─ Details (auto-populated):
                ├─ Issuer: https://sts.windows.net/{tenant-id}/
                │          OR
                │          https://login.microsoftonline.com/{tenant-id}/v2.0
                ├─ Subject: {managed-identity-client-id}
                └─ Audience: api://AzureADTokenExchange


HOW IT WORKS:
═══════════════════════════════════════════════════════════════

Step 1: Managed Identity requests its own token
┌──────────────────────────────────────────────────────────────┐
│ Container App requests token from Azure IMDS:                │
│                                                               │
│ GET http://169.254.169.254/metadata/identity/oauth2/token    │
│     ?api-version=2019-08-01                                  │
│     &resource=api://AzureADTokenExchange                     │
│     &client_id={managed-identity-client-id}                  │
│                                                               │
│ Azure IMDS returns MI token:                                 │
│ {                                                             │
│   "access_token": "eyJ0eXAi...",                            │
│   "expires_in": "86399",                                     │
│   "token_type": "Bearer"                                     │
│ }                                                             │
│                                                               │
│ MI Token Claims:                                             │
│ {                                                             │
│   "aud": "api://AzureADTokenExchange",     ← Matches!       │
│   "iss": "https://sts.windows.net/{tid}/", ← Matches!       │
│   "sub": "{managed-identity-client-id}",   ← Matches!       │
│   "appid": "{managed-identity-client-id}",                   │
│   "oid": "{managed-identity-object-id}",                     │
│   "uti": "...",                                              │
│   "rh": "..."                                                │
│ }                                                             │
└──────────────────────────────────────────────────────────────┘

Step 2: Exchange MI token for App Registration token
┌──────────────────────────────────────────────────────────────┐
│ POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
│                                                               │
│ Body:                                                         │
│   grant_type=client_credentials                              │
│   client_id={app-registration-client-id}                     │
│   client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
│   client_assertion={MI-token-from-step-1}                    │
│   scope={app-registration-client-id}/.default                │
│                                                               │
│ Entra ID validates:                                          │
│ 1. Is client_assertion a valid JWT?            ✓            │
│ 2. Is it signed by Azure AD?                   ✓            │
│ 3. Is issuer in client_assertion =                           │
│    issuer in federated credential?             ✓            │
│ 4. Is subject in client_assertion =                          │
│    subject in federated credential?            ✓            │
│ 5. Is audience in client_assertion =                         │
│    audience in federated credential?           ✓            │
│ 6. Does app registration have a federated                    │
│    credential matching these values?           ✓            │
│                                                               │
│ ALL CHECKS PASS → Issue token for app registration           │
│                                                               │
│ Returns:                                                      │
│ {                                                             │
│   "access_token": "eyJ0eXAi...",  ← Can act as app reg      │
│   "expires_in": "3599",                                      │
│   "token_type": "Bearer"                                     │
│ }                                                             │
└──────────────────────────────────────────────────────────────┘

Step 3: Use app registration token with MSAL
┌──────────────────────────────────────────────────────────────┐
│ MSAL ConfidentialClientApplication uses the token:           │
│                                                               │
│ app = ConfidentialClientApplication(                         │
│     client_id=APP_REG_CLIENT_ID,                             │
│     client_credential={                                      │
│         "client_assertion": get_token_for_client  ← Function │
│     },                                             that calls│
│     authority=AUTHORITY                            Step 1&2  │
│ )                                                             │
│                                                               │
│ Now MSAL can perform all confidential client operations:     │
│ ✓ Exchange authorization code for tokens                     │
│ ✓ Silent token refresh                                       │
│ ✓ Acquire tokens for downstream APIs                         │
│ ✓ All without a client secret!                               │
└──────────────────────────────────────────────────────────────┘


COMPARISON WITH CLIENT SECRET:
═══════════════════════════════════════════════════════════════

Client Secret Method:
┌────────────────────────────────────────────────────────────┐
│ client_credential = "xYz123..."  ← Static secret          │
│                                                             │
│ Security Issues:                                           │
│ ⚠ Must be stored somewhere                                 │
│ ⚠ Can be stolen if exposed                                 │
│ ⚠ Expires (must rotate)                                    │
│ ⚠ Same secret used for months/years                        │
└────────────────────────────────────────────────────────────┘

Federated Credential Method:
┌────────────────────────────────────────────────────────────┐
│ client_credential = {                                      │
│     "client_assertion": lambda: get_fresh_mi_token()       │
│ }                                                           │
│                                                             │
│ Security Benefits:                                         │
│ ✓ MI token automatically fetched from Azure IMDS          │
│ ✓ MI token short-lived (24 hours)                         │
│ ✓ New token fetched on each request                       │
│ ✓ MI can only be used from authorized Azure resource      │
│ ✓ Cannot be stolen or extracted                           │
│ ✓ No expiration management needed                         │
│ ✓ Automatic rotation by Azure                             │
└────────────────────────────────────────────────────────────┘
```

### D. When to Use Each Scenario

```
┌───────────────────────────────────────────────────────────────┐
│ Scenario 2: Client Secret                                    │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│ ✅ Use When:                                                  │
│   • Local development and testing                            │
│   • Deploying to non-Azure environments                      │
│   • Deploying to platforms without managed identity support  │
│   • Learning authentication flows                            │
│   • Quick prototypes                                         │
│                                                               │
│ ⚠ Be Aware:                                                  │
│   • Must manage secret lifecycle                             │
│   • Secret rotation required before expiration               │
│   • Risk of accidental secret exposure                       │
│   • Must secure secret storage                               │
│   • Compliance overhead for secret management                │
│                                                               │
└───────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────┐
│ Scenario 3: Managed Identity + Federated Credentials         │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│ ✅ Use When:                                                  │
│   • Deploying to Azure (Container Apps, App Service, VMs)    │
│   • Production workloads                                     │
│   • Security compliance requirements                         │
│   • Zero-trust architecture                                  │
│   • Want to eliminate secret management                      │
│   • Following Azure security best practices                  │
│                                                               │
│ ✓ Benefits:                                                  │
│   • Zero secrets to manage                                   │
│   • Automatic credential rotation                            │
│   • Reduced attack surface                                   │
│   • Better audit trail                                       │
│   • Simplified CI/CD (no secret injection)                   │
│   • Compliance-friendly                                      │
│                                                               │
│ ⚠ Limitations:                                               │
│   • Azure deployment required                                │
│   • Cannot test locally                                      │
│   • Federated credential setup via portal (currently)        │
│                                                               │
└───────────────────────────────────────────────────────────────┘

MIGRATION PATH:
═══════════════

Stage 1: Development
└─> Use Scenario 2 (client secret) for local development

Stage 2: Staging/Testing in Azure
└─> Migrate to Scenario 3 (managed identity) for Azure testing

Stage 3: Production
└─> Use Scenario 3 (managed identity) exclusively
    ├─> Revoke client secrets
    └─> Remove secrets from deployment pipelines


BEST PRACTICE RECOMMENDATION:
═════════════════════════════

For Azure Production Deployments:
  ✅ ALWAYS use Managed Identity with Federated Credentials
  ✅ This is Microsoft's recommended approach
  ✅ Aligns with Zero Trust security model
  ✅ Eliminates entire class of secret-related vulnerabilities
```