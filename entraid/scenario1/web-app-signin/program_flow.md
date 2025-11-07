# Program Flow Documentation

This document explains the complete flow when a user accesses the web application.

---

## Flow 1: First-Time User (Not Signed In)

### Step 1: User Opens Browser
```
User → http://localhost:5000
```

### Step 2: Flask Route `/` (index)
```python
@app.route("/")
def index():
```
- Flask receives the request
- Checks `session.get("user")`
- **Result**: `None` (no session exists yet)
- Renders `index.html` with `user=None`
- Browser displays "Sign In with Entra ID" button

### Step 3: User Clicks "Sign In"
```
User clicks button → http://localhost:5000/login
```

### Step 4: Flask Route `/login`
```python
@app.route("/login")
def login():
```
- Generates random `state` parameter (CSRF protection)
- Stores `state` in session: `session["state"] = uuid.uuid4()`
- Creates MSAL ConfidentialClientApplication instance
- Calls `get_authorization_request_url()` with:
  - `SCOPE = []` (gets default OpenID Connect scopes)
  - `state` parameter
  - `redirect_uri = "http://localhost:5000/getAToken"`
- Builds Microsoft login URL
- **Redirects browser to**: `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize?...`

### Step 5: Microsoft Entra ID Login Page
```
Browser → Microsoft Entra ID (login.microsoftonline.com)
```
- User sees Microsoft login page
- User enters username/password
- MFA if required
- Microsoft validates credentials
- Microsoft generates authorization code
- **Redirects back to**: `http://localhost:5000/getAToken?code=xxx&state=yyy`

### Step 6: Flask Route `/getAToken` (authorized)
```python
@app.route("/getAToken")
def authorized():
```
- Receives authorization code from Microsoft
- Verifies `state` parameter matches session (CSRF check)
- Creates MSAL app instance with token cache
- Calls `acquire_token_by_authorization_code()`:
  - Sends code to Microsoft
  - Microsoft validates code
  - Microsoft returns tokens:
    - **ID Token** (JWT with user info: name, email, oid, tid)
    - **Access Token** (for future API calls)
    - **Refresh Token** (to renew expired tokens)
- Stores user info in session: `session["user"] = result["id_token_claims"]`
- Serializes token cache: `session["token_cache"] = cache.serialize()`
- **Session saved to**: `flask_session/` directory on disk
- Redirects to `/` (home page)

### Step 7: Back to Flask Route `/` (index)
```python
@app.route("/")
def index():
```
- Checks `session.get("user")`
- **Result**: User info exists in session
- Renders `index.html` with user data
- Browser displays:
  - User's name
  - Email (preferred_username)
  - Tenant ID (tid)
  - Object ID (oid)
  - "Sign Out" button

---

## Flow 2: Returning User (Already Signed In)

### Step 1: User Opens Browser
```
User → http://localhost:5000
```
**Important**: Even if Flask app was restarted, session persists!

### Step 2: Browser Sends Session Cookie
```
Cookie: session=abc123...
```
- Browser automatically includes session cookie
- Cookie identifies the user's session

### Step 3: Flask Loads Session from Disk
```
Flask-Session → reads flask_session/ directory
```
- Flask-Session reads session file from `flask_session/` folder
- Session file contains:
  - `session["user"]` - User identity info
  - `session["token_cache"]` - MSAL tokens
  - `session["state"]` - CSRF token (if mid-login)

### Step 4: Flask Route `/` (index)
```python
@app.route("/")
def index():
    if not session.get("user"):  # This returns the stored user!
```
- Checks `session.get("user")`
- **Result**: User info exists (loaded from disk)
- Renders `index.html` with user data
- **User sees their profile immediately** - no login required!

### Why Session Persists After Restart
1. **Flask-Session** configured with `SESSION_TYPE = "filesystem"`
2. Session data written to `flask_session/` directory
3. Browser keeps session cookie (doesn't expire on app restart)
4. When app restarts, Flask-Session automatically:
   - Reads cookie from browser
   - Loads matching session file from disk
   - Restores all session data

---

## Flow 3: User Signs Out

### Step 1: User Clicks "Sign Out"
```
User clicks button → http://localhost:5000/logout
```

### Step 2: Flask Route `/logout`
```python
@app.route("/logout")
def logout():
```
- Calls `session.clear()`
  - Removes `session["user"]`
  - Removes `session["token_cache"]`
  - Deletes session file from `flask_session/` directory
- Builds Microsoft logout URL
- **Redirects to**: `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/logout`
- Microsoft clears their session cookies
- Microsoft redirects back to `http://localhost:5000`

### Step 3: Back to Flask Route `/` (index)
```python
@app.route("/")
def index():
```
- Checks `session.get("user")`
- **Result**: `None` (session was cleared)
- Renders `index.html` with `user=None`
- Browser displays "Sign In with Entra ID" button
- User must sign in again

---

## Session Storage Details

### Where Sessions Are Stored
```
flask_session/
├── 2029240f6d1128be89ddc32729463129  # Session file 1
├── 3f8c5a9e1234567890abcdef12345678  # Session file 2
└── ...
```
- Each file is a pickled Python dictionary
- Filename is hash of session cookie value
- Contains all session data (user info, tokens, state)

### Session File Contents (Conceptual)
```python
{
    "user": {
        "name": "John Doe",
        "preferred_username": "john.doe@company.com",
        "oid": "user-object-id",
        "tid": "tenant-id"
    },
    "token_cache": "serialized_token_data_with_access_refresh_tokens",
    "_permanent": True
}
```

### Session Lifetime
- Persists across Flask app restarts
- Persists until one of:
  - User clicks "Sign Out" (`session.clear()`)
  - Session file deleted from disk
  - Browser cookies cleared
  - Session expires (Flask default: permanent sessions don't expire)

---

## Key Functions and Their Role

### `_build_msal_app(cache=None)`
- Creates MSAL ConfidentialClientApplication
- Uses `CLIENT_ID`, `CLIENT_SECRET`, `AUTHORITY` from config
- Optionally loads token cache for silent token refresh

### `_load_cache()`
- Loads serialized token cache from session
- Returns MSAL TokenCache object
- **Called on every request that needs tokens**
- Enables token refresh without re-authentication

### `_save_cache(cache)`
- Serializes token cache to session
- Saves to `flask_session/` via Flask-Session
- **Persists tokens across app restarts**

### `_get_token_from_cache(scope=None)`
- Attempts to get valid token from cache
- Calls `acquire_token_silent()` (no user interaction)
- Automatically refreshes expired tokens using refresh token
- Returns `None` if no cached token (user must sign in)

---

## MSAL Token Flow

### Token Types
1. **ID Token** (JWT)
   - Contains user identity claims
   - Stored in `session["user"]`
   - Used to display user info

2. **Access Token**
   - Used to call APIs (Microsoft Graph, etc.)
   - Stored in token cache
   - Short-lived (typically 1 hour)

3. **Refresh Token**
   - Used to get new access tokens
   - Stored in token cache
   - Long-lived (typically 90 days)

### Silent Token Refresh
```python
result = auth_app.acquire_token_silent(scope, account=accounts[0])
```
- Checks if valid access token exists in cache
- If expired, automatically uses refresh token
- Gets new access token without user interaction
- Updates token cache
- **User never sees login page again** (until refresh token expires)

---

## Complete Request/Response Flow Diagram

```
First Time Sign-In:
┌─────────┐    GET /           ┌──────────┐
│ Browser │ ──────────────────> │  Flask   │
└─────────┘                     │  app.py  │
     ↑                          └────┬─────┘
     │ HTML (Sign In button)         │ session.get("user") = None
     └───────────────────────────────┘

     ┌─────────┐    GET /login      ┌──────────┐
     │ Browser │ ──────────────────> │  Flask   │
     └─────────┘                     │  app.py  │
          ↑                          └────┬─────┘
          │ Redirect to Microsoft         │ Build auth URL
          └───────────────────────────────┘

┌─────────┐    GET /authorize   ┌──────────────┐
│ Browser │ ──────────────────> │  Microsoft   │
└─────────┘                     │  Entra ID    │
     ↑                          └──────┬───────┘
     │ Show login page                 │
     └─────────────────────────────────┘

     User enters credentials
     Microsoft validates

┌─────────┐    Redirect         ┌──────────────┐
│ Browser │ <────────────────── │  Microsoft   │
└─────────┘ code=xxx&state=yyy  │  Entra ID    │
     │                          └──────────────┘
     │ GET /getAToken?code=xxx
     ↓
┌──────────┐                    
│  Flask   │ Exchange code for tokens
│  app.py  │ Save to session["user"]
└────┬─────┘ Save to flask_session/ disk
     │ Redirect to /
     ↓
┌─────────┐    GET /           ┌──────────┐
│ Browser │ ──────────────────> │  Flask   │
└─────────┘                     │  app.py  │
     ↑                          └────┬─────┘
     │ HTML (user profile)           │ session.get("user") = {...}
     └───────────────────────────────┘


Returning User (App Restarted):
┌─────────┐    GET /           ┌──────────┐
│ Browser │ ──────────────────> │  Flask   │ (NEW PROCESS)
└─────────┘ Cookie: session=... │  app.py  │
     ↑                          └────┬─────┘
     │                               │ Read cookie
     │                               │ Load flask_session/abc123
     │                               │ session.get("user") = {...}
     │                               │
     │ HTML (user profile)           │ User logged in!
     └───────────────────────────────┘
```

---

## Summary

**First Visit**: User → Sign In Button → Microsoft Login → Auth Code → Tokens → Session Saved → User Profile Displayed

**Return Visit**: User → Flask Loads Session from Disk → User Profile Displayed (No Login!)

**Sign Out**: User → Session Cleared from Disk → Sign In Button

**Key Insight**: The `flask_session/` directory acts as persistent storage, allowing sessions to survive Flask app restarts. This is why users stay logged in even after you stop and restart `python3 app.py`.
