# Scenario 2: Web App Calls Protected API

This scenario demonstrates a Python web application that signs in users and calls a protected web API on behalf of the signed-in user. Both the web app and API are deployed to Azure Container Apps.

Based on Microsoft's tutorial: [Call an API from a web app](https://learn.microsoft.com/entra/identity-platform/tutorial-web-app-python-call-api-overview)

## Architecture

**Components:**
- **Web Application**: Flask app that authenticates users and acquires access tokens
- **Protected API**: Flask API that validates access tokens and returns claims
- **Entra ID**: Two app registrations (API as resource, Web App as client)
- **Azure Container Apps**: Cloud hosting for both applications

**Authentication Flow:**
1. User signs into Web App using Entra ID (OpenID Connect)
2. Web App acquires access token with delegated permission scope
3. Web App calls Protected API with access token in Authorization header
4. API validates the JWT token and returns user claims

## Prerequisites

- Azure subscription with permissions to create app registrations
- Azure CLI installed and authenticated (`az login`)
- Python 3.7+ (for local testing)
- Docker (for containerization)

## Quick Start

### Option 1: Local Testing

1. **Set up Entra ID app registrations:**
```bash
cd entraid/scenario2
source ./setup-entraid.sh
```

This creates:
- API app registration with exposed OAuth2 scope `api://{appid}/access_as_user`
- Web app registration with granted API permission
- Exports environment variables automatically

2. **Run the API (Terminal 1):**
```bash
cd api
pip install -r requirements.txt
python3 app.py
```

API runs at `http://localhost:5001`

3. **Run the Web App (Terminal 2):**
```bash
cd web-app
pip install -r requirements.txt
python3 app.py
```

Web app runs at `http://localhost:5000`

4. **Test the flow:**
- Open http://localhost:5000
- Click "Sign In" and authenticate
- Click "Call Protected API"
- View the claims returned from the API

### Option 2: Deploy to Azure Container Apps

1. **Set up Entra ID (if not done):**
```bash
source ./setup-entraid.sh
```

2. **Deploy to Azure:**
```bash
./deploy-to-azure.sh
```

This will:
- Create resource group and Azure Container Registry
- Build and push Docker images for both apps
- Create Container Apps Environment
- Deploy API and Web App containers
- Update Entra ID redirect URI for production URL
- Output the public URLs for both apps

3. **Access your apps:**
- Web App: `https://<web-app-fqdn>` (shown in script output)
- API: `https://<api-fqdn>` (shown in script output)

## Project Structure

```
scenario2/
├── api/
│   ├── app.py              # Protected API with JWT validation
│   ├── requirements.txt    # API dependencies
│   └── Dockerfile          # API container image
├── web-app/
│   ├── app.py              # Web app with MSAL integration
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
- [MSAL Python Documentation](https://msal-python.readthedocs.io/)
- [Azure Container Apps Documentation](https://learn.microsoft.com/azure/container-apps/)
- [JWT Token Validation](https://jwt.io/)

