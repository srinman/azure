# Scenario 1: Web App that Signs In a User

Complete implementation of Microsoft Entra ID authentication for web applications.

## Prerequisites

- Azure subscription
- Azure CLI installed: `az --version`
- Python 3.7+: `python3 --version`
- Logged into Azure: `az login`

## Setup Steps

### Step 1: Create Entra ID App Registration and Set Environment Variables

```bash
cd web-app-signin
source ./setup-entraid.sh
```

**Important**: Use `source` (not `./`) to export environment variables to your current shell session.

This command:
- Creates app registration in Entra ID
- Generates client secret
- Configures redirect URI (http://localhost:5000/getAToken)
- Enables ID token issuance
- **Automatically exports CLIENT_ID, CLIENT_SECRET, and TENANT_ID as environment variables**

### Step 2: Install Dependencies

```bash
pip install -r requirements.txt
```

### Step 3: Run the Application

```bash
python3 app.py
```

Or use the convenience script that handles everything:

```bash
./run-app.sh
```

### Step 4: Test

1. Open browser to `http://localhost:5000`
2. Click "Sign In with Entra ID"
3. Authenticate with your work/school account
4. See your user profile information displayed

## What You Get

When a user signs in, the application displays:
- User's display name
- Email address (preferred_username)
- Tenant ID
- Object ID

This information comes from the **ID token** - no additional API calls required.

## Project Structure

```
web-app-signin/
├── app.py                 # Flask application with MSAL integration
├── app_config.py          # Configuration (reads from env vars)
├── requirements.txt       # Python dependencies
├── setup-entraid.sh       # Azure CLI setup script
├── run-app.sh            # Convenience launcher
└── templates/            # HTML templates
    ├── index.html        # Home page with sign-in
    ├── display.html      # Reserved for future use
    └── auth_error.html   # Error handling
```

## Manual Azure CLI Commands

If you prefer to run commands manually instead of using `setup-entraid.sh`:

```bash
# Create app registration
az ad app create \
    --display-name "webapp-signin-demo" \
    --sign-in-audience "AzureADMyOrg" \
    --web-redirect-uris "http://localhost:5000/getAToken" \
    --enable-id-token-issuance true

# Get the app ID from the output, then create a secret
az ad app credential reset --id <APP_ID> --append

# Get your tenant ID
az account show --query tenantId -o tsv
```

## Troubleshooting

**"ValueError: Unable to get authority configuration"**
- Environment variables not set. Run the export commands before starting the app.

**"AADSTS50011: redirect URI mismatch"**
- Verify redirect URI is exactly: `http://localhost:5000/getAToken`

**Import errors**
- Run: `pip install -r requirements.txt`

## Production Deployment

For production:

1. Update redirect URI in Entra ID:
   ```bash
   az ad app update --id <APP_ID> \
       --web-redirect-uris "https://yourdomain.com/getAToken"
   ```

2. Use environment variables (don't hardcode secrets)

3. Enable HTTPS

4. Use a production WSGI server:
   ```bash
   pip install gunicorn
   gunicorn -w 4 app:app
   ```

## Security Notes

- Never commit `CLIENT_SECRET` to source control
- Use environment variables or Azure Key Vault for secrets
- Enable HTTPS in production
- The app uses CSRF protection via state parameter

---

## Appendix: Architecture Flow

### Authentication Flow Diagram

```
┌─────────────┐
│   Browser   │  1. User visits http://localhost:5000
│   (User)    │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────┐
│   Flask App (/)             │  2. Shows sign-in page
│   - Display "Sign In" btn   │
└──────┬──────────────────────┘
       │
       │ 3. User clicks "Sign In"
       ▼
┌─────────────────────────────┐
│   Flask App (/login)        │  4. Generate auth URL
│   - Create state (CSRF)     │     Redirect to Entra ID
│   - Build MSAL auth URL     │
└──────┬──────────────────────┘
       │
       │ 5. Redirect to Microsoft
       ▼
┌─────────────────────────────┐
│   Microsoft Entra ID        │  6. User authenticates
│   - Login page              │     - Username/password
│   - Validate credentials    │     - MFA (if enabled)
└──────┬──────────────────────┘
       │
       │ 7. Redirect with auth code
       │    http://localhost:5000/getAToken?code=xxx&state=yyy
       ▼
┌─────────────────────────────┐
│   Flask App (/getAToken)    │  8. Exchange code for tokens
│   - Verify state            │     - ID token (user info)
│   - Call MSAL               │     - Access token
│   - Store user in session   │     - Refresh token
└──────┬──────────────────────┘
       │
       │ 9. Redirect to home
       ▼
┌─────────────────────────────┐
│   Flask App (/)             │  10. Display user info
│   - Read from session       │      - name
│   - Show user profile       │      - preferred_username
│   - Display sign-out btn    │      - tid, oid
└─────────────────────────────┘
```

### Token Exchange Detail

```
Step 1: Authorization Request
┌─────────────┐                  ┌──────────────┐
│  Flask App  │─────────────────>│  Entra ID    │
└─────────────┘                  └──────────────┘
  Parameters:
  - client_id
  - redirect_uri
  - response_type=code
  - state=random_csrf_token

Step 2: User Authentication
┌─────────────┐                  ┌──────────────┐
│    User     │<─────────────────│  Entra ID    │
└─────────────┘                  └──────────────┘
  User enters credentials

Step 3: Authorization Code
┌─────────────┐                  ┌──────────────┐
│  Flask App  │<─────────────────│  Entra ID    │
└─────────────┘                  └──────────────┘
  Returns:
  - code=authorization_code
  - state=same_csrf_token

Step 4: Token Request
┌─────────────┐                  ┌──────────────┐
│  Flask App  │─────────────────>│  Entra ID    │
└─────────────┘                  └──────────────┘
  Sends:
  - grant_type=authorization_code
  - code=authorization_code
  - client_id
  - client_secret
  - redirect_uri

Step 5: Tokens Response
┌─────────────┐                  ┌──────────────┐
│  Flask App  │<─────────────────│  Entra ID    │
└─────────────┘                  └──────────────┘
  Receives:
  - id_token (JWT with user info)
  - access_token
  - refresh_token
  - expires_in
```

### Session Management

```
User Signs In
│
├─> MSAL acquires tokens
│   ├─> ID Token (user identity)
│   ├─> Access Token (for future API calls)
│   └─> Refresh Token (token renewal)
│
├─> Flask stores in session
│   └─> session["user"] = id_token_claims
│   └─> session["token_cache"] = serialized_cache
│
└─> Session persisted to filesystem
    └─> flask_session/ directory

On subsequent requests:
├─> Load from session
├─> Verify not expired
└─> Display user info
```

### Azure Resources Created

```
Entra ID Tenant
│
└── App Registration: "webapp-signin-demo"
    ├── Application (Client) ID
    ├── Directory (Tenant) ID
    │
    ├── Authentication
    │   ├── Platform: Web
    │   ├── Redirect URI: http://localhost:5000/getAToken
    │   └── ID tokens: Enabled
    │
    └── Certificates & secrets
        └── Client secret (password-based credential)
```

### ID Token Contents

The ID token is a JWT containing user information:

```json
{
  "aud": "client-id",
  "iss": "https://login.microsoftonline.com/tenant-id/v2.0",
  "iat": 1699370000,
  "exp": 1699373600,
  "name": "John Doe",
  "preferred_username": "john.doe@company.com",
  "oid": "user-object-id",
  "tid": "tenant-id",
  "sub": "subject-id"
}
```

This information is displayed automatically without calling any external APIs.

## References

- [Microsoft identity platform documentation](https://learn.microsoft.com/en-us/entra/identity-platform/)
- [Web app that signs in users](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-web-app-sign-user-overview)
- [MSAL Python](https://msal-python.readthedocs.io/)


