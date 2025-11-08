# Step-by-Step Program Explanation: Web App Calling Protected API (Scenario 2)

This document provides a detailed line-by-line explanation of how the web app authenticates users and calls a protected API using OAuth 2.0 and access tokens.

---

## Table of Contents
1. [Overview](#overview)
2. [Key Differences from Scenario 1](#key-differences-from-scenario-1)
3. [Imports and Setup](#imports-and-setup)
4. [Routes (Same as Scenario 1)](#routes-same-as-scenario-1)
5. [New Route: Call API (/call-api)](#new-route-call-api-call-api)
6. [Helper Functions](#helper-functions)
7. [Complete Flow: Calling Protected API](#complete-flow-calling-protected-api)
8. [Understanding Access Tokens vs ID Tokens](#understanding-access-tokens-vs-id-tokens)

---

## Overview

**Scenario 2 extends Scenario 1** by adding the ability to call a protected API:

- **Scenario 1:** User signs in, gets ID token, app displays user info
- **Scenario 2:** User signs in, gets BOTH ID token AND access token, app uses access token to call protected API

**New capabilities:**
- Requests API scopes during login
- Acquires access tokens for calling APIs
- Calls protected API with Bearer token authentication
- Handles API responses and errors

---

## Key Differences from Scenario 1

### Configuration Changes (app_config.py)

```python
# API Client ID (the protected API's application ID)
API_CLIENT_ID = os.getenv("API_CLIENT_ID", "YOUR_API_CLIENT_ID")

# Scopes - requesting access to the API
SCOPE = [f"api://{API_CLIENT_ID}/access_as_user"]

# API endpoint URL
API_ENDPOINT = os.getenv("API_ENDPOINT", "http://localhost:5001/api/claims")
```

**Line-by-line:**
- `API_CLIENT_ID` - The client ID of the protected API (different from web app's CLIENT_ID)
- `SCOPE = [f"api://{API_CLIENT_ID}/access_as_user"]` - The permission we're requesting
  - Format: `api://{API_CLIENT_ID}/{scope_name}`
  - Example: `api://12345678-api-guid/access_as_user`
  - **Scenario 1 had empty list `[]`** - only requested basic sign-in
  - **Scenario 2 requests API access** - gets access token for the API
- `API_ENDPOINT` - URL where the protected API is running

### Code Changes

1. **Import `requests`** - For making HTTP calls to the API
2. **New route `/call-api`** - Handles calling the protected API
3. **Same authentication flow** - Login, logout, session management unchanged

---

## Imports and Setup

```python
import uuid
import requests
from flask import Flask, render_template, session, request, redirect, url_for
from flask_session import Session
import msal
import app_config
```

**New import:**
- `import requests` - HTTP library for calling the protected API
  - Used to make GET request with Bearer token

**All other imports same as Scenario 1**

---

## Routes (Same as Scenario 1)

The following routes work **exactly the same** as Scenario 1:

- **`/` (index)** - Home page showing login status
- **`/login`** - Initiates OAuth flow
- **`/getAToken` (authorized)** - Handles callback from Microsoft
- **`/logout`** - Signs user out

**Key difference in the flow:**
When user logs in, because `SCOPE` is not empty, Microsoft will:
1. Ask user to consent to the API permission (first time only)
2. Return authorization code as before
3. When code is exchanged for tokens, BOTH ID token AND access token are returned

---

## New Route: Call API (/call-api)

This is the main new feature - calling a protected API with an access token.

```python
@app.route("/call-api")
def call_api():
    """Call the protected API and display claims"""
```
- User navigates to `/call-api` (typically by clicking a button on the home page)
- This route will get an access token and call the API

### Step 1: Get Access Token from Cache

```python
    token = _get_token_from_cache(app_config.SCOPE)
```
- Calls `_get_token_from_cache()` with API scope
- **Tries to get access token WITHOUT asking user to log in again**
- Returns token dictionary or `None`

**What `_get_token_from_cache()` does:**
1. Loads cached tokens from session
2. Checks if we have a valid access token for this scope
3. If token expired, uses refresh token to get new one automatically
4. Returns token if available, `None` if not

### Step 2: Check if Token Was Acquired

```python
    if not token:
        return redirect(url_for("login"))
```
- `if not token:` - Token acquisition failed
- **Reasons for failure:**
  - User not logged in (no cached account)
  - Refresh token expired (rare - user needs to log in again)
- `redirect(url_for("login"))` - Send user to login page

### Step 3: Prepare API Request

```python
    # Call the protected API
    api_url = app_config.API_ENDPOINT
    headers = {'Authorization': 'Bearer ' + token['access_token']}
```

**Line-by-line:**
- `api_url = app_config.API_ENDPOINT` - Get API URL from config
  - Example: `"http://localhost:5001/api/claims"`
- `headers = {'Authorization': 'Bearer ' + token['access_token']}` - Create HTTP headers
  - `token['access_token']` - The access token string (JWT format)
  - `'Bearer ' + ...` - Standard format for OAuth 2.0 token authentication
  - Example: `{'Authorization': 'Bearer eyJ0eXAiOiJKV1QiLCJhbGc...'}`

**About Bearer Tokens:**
- "Bearer" means "whoever bears (carries) this token is authorized"
- Standard way to send access tokens in HTTP requests
- Format: `Authorization: Bearer {token}`

### Step 4: Make HTTP Request to API

```python
    try:
        response = requests.get(api_url, headers=headers)
```
- `requests.get(api_url, headers=headers)` - Makes HTTP GET request
  - `api_url` - Where to send the request
  - `headers=headers` - Includes the Authorization header with Bearer token
- `response` - Response object containing status code, headers, body

**What happens:**
1. HTTP GET request sent to API
2. API receives request with Bearer token
3. API validates the token (checks signature, expiration, audience)
4. API returns response (success or error)

### Step 5: Handle Successful Response

```python
        if response.status_code == 200:
            api_data = response.json()
            return render_template('api_response.html', 
                                 result=api_data,
                                 api_url=api_url)
```

**Line-by-line:**
- `if response.status_code == 200:` - Check if API returned success
  - `200` = HTTP OK status
- `api_data = response.json()` - Parse JSON response body
  - API returns JSON with claims from the access token
- `render_template('api_response.html', ...)` - Display results to user
  - `result=api_data` - The claims data from API
  - `api_url=api_url` - Show which API was called

**Example `api_data` content:**
```json
{
  "message": "Successfully validated token",
  "claims": {
    "aud": "api://12345678-api-guid",
    "name": "John Doe",
    "preferred_username": "john@company.com",
    "scp": "access_as_user",
    ...
  }
}
```

### Step 6: Handle API Error Response

```python
        else:
            error_data = {
                "error": f"API returned status {response.status_code}",
                "details": response.text
            }
            return render_template('api_error.html', result=error_data)
```

**Line-by-line:**
- `else:` - API returned non-200 status code
- `error_data = {...}` - Create error object
  - `response.status_code` - HTTP status (401, 403, 500, etc.)
  - `response.text` - Raw response body (error message from API)
- `render_template('api_error.html', ...)` - Display error to user

**Common error codes:**
- `401 Unauthorized` - Token invalid, expired, or missing
- `403 Forbidden` - Token valid but insufficient permissions
- `500 Internal Server Error` - API had an error

### Step 7: Handle Connection/Network Errors

```python
    except Exception as e:
        error_data = {
            "error": "Failed to call API",
            "details": str(e)
        }
        return render_template('api_error.html', result=error_data)
```

**Line-by-line:**
- `except Exception as e:` - Catches any exception during API call
- **Common exceptions:**
  - `requests.ConnectionError` - Can't reach API (not running, wrong URL)
  - `requests.Timeout` - API too slow to respond
  - `requests.RequestException` - Other network errors
- `str(e)` - Convert exception to string for display
- Display error page to user

---

## Helper Functions

### _get_token_from_cache(scope=None)

This function is **critical** for Scenario 2 - it gets access tokens for calling APIs.

```python
def _get_token_from_cache(scope=None):
    """Attempt to retrieve a token from the cache"""
    cache = _load_cache()
    auth_app = _build_msal_app(cache=cache)
```
- `cache = _load_cache()` - Load cached tokens from session
- `auth_app = _build_msal_app(cache=cache)` - Create MSAL app with cache

```python
    accounts = auth_app.get_accounts()
```
- `auth_app.get_accounts()` - Get list of accounts in cache
- Returns list of user accounts that have logged in
- Example: `[{'username': 'john@company.com', 'environment': 'login.microsoftonline.com', ...}]`
- Empty list if no one logged in

```python
    if accounts:
        result = auth_app.acquire_token_silent(scope, account=accounts[0])
        _save_cache(cache)
        return result
```

**Line-by-line:**
- `if accounts:` - Check if any account exists
- `auth_app.acquire_token_silent(scope, account=accounts[0])` - **KEY FUNCTION**
  - `scope` - The API scope we need (e.g., `["api://{API_ID}/access_as_user"]`)
  - `account=accounts[0]` - Which user account to use
  - **"Silent"** means NO user interaction (no redirect to Microsoft)
  
**What `acquire_token_silent()` does:**
1. Checks cache for valid access token for this scope
2. **If found and not expired** → Returns it immediately
3. **If expired** → Uses refresh token to get new access token from Microsoft (automatic)
4. **If successful** → Returns token dictionary
5. **If failed** → Returns `None`

**Returned token dictionary:**
```python
{
    "access_token": "eyJ0eXAiOiJKV1QiLCJh...",  # For calling API
    "token_type": "Bearer",
    "expires_in": 3599,
    "scope": "api://12345-api/access_as_user",
    "refresh_token": "0.AXoA..."  # For getting new tokens
}
```

- `_save_cache(cache)` - Save updated cache (in case token was refreshed)
- `return result` - Return token dictionary

```python
    return None
```
- If no accounts in cache, return `None`
- Caller should redirect to login

**Why this is powerful:**
- User logged in once, can call API many times
- Access tokens auto-refresh when expired
- No user interaction needed for API calls
- Seamless user experience

### Other Helper Functions

These are **identical to Scenario 1:**
- `_load_cache()` - Load tokens from session
- `_save_cache(cache)` - Save tokens to session
- `_build_msal_app(cache, authority)` - Create MSAL app object

---

## Complete Flow: Calling Protected API

### First-Time User Flow

1. **User visits home page (`/`)**
   - Not logged in, sees "Sign In" button

2. **User clicks "Sign In"**
   - Redirected to `/login`

3. **Login flow (same as Scenario 1, but with scope)**
   - State generated
   - Redirected to Microsoft with scope: `api://{API_ID}/access_as_user`

4. **User logs in at Microsoft**
   - **Microsoft shows consent screen:** "App wants to access API on your behalf"
   - User clicks "Accept"

5. **Microsoft redirects back with authorization code**
   - App at `/getAToken` receives code

6. **App exchanges code for tokens**
   - Sends code + CLIENT_SECRET to Microsoft
   - **Receives BOTH:**
     - ID token (user identity)
     - **Access token (for calling API)**
     - Refresh token (for getting new tokens)

7. **Tokens saved to cache**
   - `session["user"]` = ID token claims
   - `session["token_cache"]` = All tokens (ID, access, refresh)

8. **User now on home page, logged in**
   - Home page shows "Call API" button

9. **User clicks "Call API"**
   - Browser navigates to `/call-api`

10. **App gets access token from cache**
    - `_get_token_from_cache(SCOPE)` called
    - Finds valid access token in cache
    - Returns immediately (no user interaction)

11. **App calls protected API**
    - HTTP GET with `Authorization: Bearer {access_token}`
    - API validates token
    - API returns claims

12. **Results displayed to user**
    - Shows claims from access token
    - User sees their name, permissions, token details

### Subsequent API Calls (Same Session)

1. **User clicks "Call API" again**
   - Same access token used (still valid)
   - Fast - no token refresh needed
   - Direct API call

### After Access Token Expires (Typically 1 Hour)

1. **User clicks "Call API" after 1 hour**
   - Access token expired

2. **`acquire_token_silent()` automatically:**
   - Detects expired access token
   - Uses refresh token to get new access token
   - **No user interaction needed**
   - Updates cache with new token

3. **App calls API with fresh token**
   - User doesn't notice anything
   - Seamless experience

---

## Understanding Access Tokens vs ID Tokens

### ID Token
**Purpose:** Prove WHO the user is

**When acquired:** During user login

**Contents:** User identity claims
```json
{
  "name": "John Doe",
  "preferred_username": "john@company.com",
  "oid": "user-object-id",
  "tid": "tenant-id"
}
```

**Used for:** Displaying user info in the web app

**Audience:** The web app's CLIENT_ID

**In this app:** Stored in `session["user"]`, displayed on home page

### Access Token
**Purpose:** Prove the user has PERMISSION to access an API

**When acquired:** During login (if scope requested) OR when calling `acquire_token_silent()`

**Contents:** Permissions and authorization claims
```json
{
  "aud": "api://12345-api-guid",  // API being accessed
  "scp": "access_as_user",         // Permissions granted
  "appid": "web-app-client-id",    // App making the call
  "name": "John Doe",              // Who the user is
  "oid": "user-object-id"
}
```

**Used for:** Calling protected APIs (sent in Authorization header)

**Audience:** The API's CLIENT_ID (NOT the web app's)

**In this app:** Cached in `session["token_cache"]`, sent to API as Bearer token

### Key Differences

| Feature | ID Token | Access Token |
|---------|----------|--------------|
| **Purpose** | Identity | Authorization |
| **Audience** | Web App | API |
| **Where used** | Web app displays info | Sent to API |
| **Typical lifetime** | 1 hour | 1 hour |
| **Can be refreshed?** | No (use refresh token to get new one) | Yes (use refresh token) |
| **Format** | JWT (JSON Web Token) | JWT (JSON Web Token) |

### Refresh Token
**Purpose:** Get new access tokens without user re-login

**When acquired:** During initial login

**Lifetime:** Long (days/weeks/months depending on policy)

**Used for:** Automatically refreshing expired access tokens

**In this app:** Stored in cache, used by `acquire_token_silent()`

---

## OAuth 2.0 Scopes Explained

### What is a Scope?

A **scope** is a permission that defines what an access token can do.

**Format:** `api://{API_CLIENT_ID}/{scope_name}`

**Example:** `api://12345678-api-guid/access_as_user`

**Parts:**
- `api://` - Protocol prefix for API resources
- `{API_CLIENT_ID}` - The API's application ID (GUID)
- `{scope_name}` - Name of the permission (defined by API owner)

### Common Scope Names

- `access_as_user` - Access API on behalf of signed-in user
- `read` - Read-only access
- `write` - Write access
- `admin` - Administrative access

### How Scopes Work

1. **Web app requests scope during login**
   ```python
   SCOPE = ["api://12345-api/access_as_user"]
   ```

2. **User sees consent screen**
   - "App wants to: Access API on your behalf"
   - User must click "Accept"

3. **Microsoft issues access token with scope**
   - Access token contains: `"scp": "access_as_user"`

4. **API validates scope**
   - Checks token has required scope
   - Rejects if scope missing

### Multiple Scopes

You can request multiple scopes:
```python
SCOPE = [
    "api://api1-guid/read",
    "api://api2-guid/write",
    "https://graph.microsoft.com/User.Read"
]
```

---

## Security Considerations

### Access Token Security

**Why access tokens must be protected:**
- Anyone with access token can call API as the user
- If stolen, attacker can access protected resources

**Best practices:**
1. **Never expose in client-side code** - Keep on server
2. **Use HTTPS** - Encrypt during transmission
3. **Short lifetime** - Tokens expire in 1 hour
4. **Store securely** - Server-side session storage
5. **Validate on API** - API must verify token signature, audience, expiration

### In This App

✅ **Access tokens stored server-side** - In `session["token_cache"]` (filesystem)

✅ **Never sent to browser** - Only used in server-to-server API calls

✅ **HTTPS required in production** - ProxyFix middleware for proper scheme detection

✅ **API validates tokens** - API verifies signature using Microsoft's public keys

---

## Common Scenarios and Troubleshooting

### Scenario: API Returns 401 Unauthorized

**Possible causes:**
1. Access token expired (shouldn't happen - auto-refresh)
2. Token audience doesn't match API
3. Token signature invalid
4. API_CLIENT_ID misconfigured

**Debugging:**
- Check API logs for specific error
- Verify `SCOPE` in web app config matches API expected audience
- Check `API_CLIENT_ID` in both web app and API configs match

### Scenario: User Not Prompted for Consent

**Explanation:** 
- Consent only required on first login
- Microsoft remembers user's consent
- Subsequent logins skip consent screen

**To re-test consent:**
- Logout from Microsoft completely
- Revoke app permissions in Azure portal
- Login again

### Scenario: Access Token Missing Scope

**Possible causes:**
1. Scope not requested during login
2. Scope not exposed by API in Azure registration
3. API permission not granted to web app in Azure

**Fix:**
- Verify `SCOPE` in app_config.py
- Check API app registration exposes scope
- Check web app has API permission granted

---

## Summary

**Scenario 2 adds API calling capabilities to Scenario 1:**

1. **Requests API scope during login** - Gets access token
2. **Caches access token** - Stored with ID token and refresh token
3. **Retrieves token silently** - Uses `acquire_token_silent()` to get cached or refreshed token
4. **Calls API with Bearer token** - Sends access token in Authorization header
5. **API validates token** - Verifies signature, audience, expiration
6. **Displays results** - Shows claims from access token

**Key components:**
- **OAuth 2.0 scopes** - Define API permissions
- **Access tokens** - Authorize API calls
- **Refresh tokens** - Auto-renew expired access tokens
- **Bearer authentication** - Standard way to send tokens to APIs
- **Silent token acquisition** - Get tokens without user interaction

**Flow summary:**
1. User logs in → Gets ID token + access token + refresh token
2. User clicks "Call API" → App gets access token from cache
3. App calls API → Sends Bearer token
4. API validates token → Returns data
5. Token expires → Auto-refreshed using refresh token
6. User never re-logs in → Seamless experience
