# Step-by-Step Program Explanation: Entra ID Authentication Flow

This document provides a detailed line-by-line explanation of how the authentication flow works in this Flask web application using MSAL (Microsoft Authentication Library).

---

## Table of Contents
1. [Imports and Setup](#imports-and-setup)
2. [Home Page Route (/)](#home-page-route-)
3. [Login Route (/login)](#login-route-login)
4. [Authorization Callback Route (/getAToken)](#authorization-callback-route-getatoken)
5. [Logout Route (/logout)](#logout-route-logout)
6. [Helper Functions](#helper-functions)
7. [Complete Authentication Flow](#complete-authentication-flow)

---

## Imports and Setup

```python
import uuid
from flask import Flask, render_template, session, request, redirect, url_for
from flask_session import Session
import msal
import app_config
```

**Line-by-line:**
- `import uuid` - For generating unique random identifiers (used for CSRF protection)
- `from flask import ...` - Flask web framework components
  - `Flask` - Main app class
  - `render_template` - Renders HTML templates
  - `session` - Dictionary-like object to store user-specific data across requests
  - `request` - Contains incoming HTTP request data (URL parameters, form data, etc.)
  - `redirect` - Sends HTTP redirect response to browser
  - `url_for` - Generates URLs for Flask routes
- `from flask_session import Session` - Extension for server-side session storage (saves sessions to disk)
- `import msal` - Microsoft Authentication Library - handles OAuth 2.0 protocol
- `import app_config` - Configuration file with CLIENT_ID, CLIENT_SECRET, TENANT_ID

```python
app = Flask(__name__)
app.config.from_object(app_config)
Session(app)
```

**Line-by-line:**
- `app = Flask(__name__)` - Creates the Flask application instance
- `app.config.from_object(app_config)` - Loads configuration from app_config.py (SESSION_TYPE, SECRET_KEY, etc.)
- `Session(app)` - Initializes Flask-Session with filesystem storage
  - Sessions are saved to `flask_session/` directory
  - Each user gets a separate session file
  - Sessions survive app restarts

```python
from werkzeug.middleware.proxy_fix import ProxyFix
app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1, x_host=1)
```

**Line-by-line:**
- `ProxyFix` - Middleware that fixes URL scheme detection when behind a reverse proxy
- `x_proto=1` - Trust 1 proxy for protocol (http/https)
- `x_host=1` - Trust 1 proxy for host header
- **Why needed:** When deployed behind a reverse proxy (like nginx or Azure App Service), the app needs to know the original scheme (https) to generate correct redirect URLs

---

## Home Page Route (/)

```python
@app.route("/")
def index():
```
- `@app.route("/")` - Decorator that maps the root URL to this function
- `def index():` - Function that handles requests to the home page

```python
    if not session.get("user"):
        return render_template('index.html', user=None, version=msal.__version__)
```
- `session.get("user")` - Attempts to retrieve "user" key from session dictionary
  - Returns `None` if key doesn't exist (user not logged in)
  - Returns user info dictionary if exists (user is logged in)
- `if not session.get("user"):` - Checks if user is NOT logged in
- `return render_template('index.html', user=None, ...)` - Renders template with no user data
  - Template will show "Sign In" button

```python
    return render_template('index.html', 
                         user=session["user"], 
                         version=msal.__version__)
```
- This line executes if user IS logged in
- `user=session["user"]` - Passes user information to template
  - Contains name, email, user ID from Microsoft
- Template will show "Welcome [name]!" and "Sign Out" button

---

## Login Route (/login)

### Step 1: Generate CSRF Protection Token

```python
@app.route("/login")
def login():
    """Initiate authentication flow"""
```
- This route is triggered when user clicks "Sign In" button

```python
    session["state"] = str(uuid.uuid4())
```
- `uuid.uuid4()` - Generates a random UUID like `UUID('3a7f2c9d-8b1e-4f6a-9c2d-5e8f1a3b7c9d')`
- `str(...)` - Converts to string: `"3a7f2c9d-8b1e-4f6a-9c2d-5e8f1a3b7c9d"`
- `session["state"] = ...` - Stores in THIS USER'S session dictionary
  - Each user has their own session
  - Saved to disk in `flask_session/` directory
  - Browser receives a session cookie to retrieve it later
- **Purpose:** CSRF (Cross-Site Request Forgery) protection
  - We'll verify Microsoft sends this exact value back
  - Prevents attackers from tricking users into logging in with attacker's credentials

### Step 2: Create MSAL Application Object

```python
    auth_app = _build_msal_app()
```
- Calls helper function `_build_msal_app()` (defined later)
- Returns a `ConfidentialClientApplication` object configured with:
  - `CLIENT_ID` - Your app's ID from Azure registration
  - `CLIENT_SECRET` - Your app's password (proves app identity)
  - `AUTHORITY` - Microsoft login URL for your tenant
- **What it does:** Creates an object that knows how to talk to Microsoft's authentication service

### Step 3: Build Microsoft Login URL

```python
    auth_url = auth_app.get_authorization_request_url(
        app_config.SCOPE,  # Scopes requested
        state=session["state"],
        redirect_uri=url_for("authorized", _external=True)
    )
```

**Parameter-by-parameter:**

- `app_config.SCOPE` - List of permissions requested (in this app: `[]` empty = just basic sign-in)
  - For other apps, could be: `["User.Read", "Mail.Read"]` to access user profile and email
- `state=session["state"]` - Includes the random UUID we just created
  - Microsoft will echo this back when redirecting
- `redirect_uri=url_for("authorized", _external=True)` - Where Microsoft should send user after login
  - `url_for("authorized", _external=True)` generates: `"http://localhost:5000/getAToken"`
  - `_external=True` means include the full domain, not just `/getAToken`
  - Must match what's registered in Azure app registration

**Result:** `auth_url` is a string like:
```
https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/authorize?
  client_id=abc123...
  &response_type=code
  &redirect_uri=http://localhost:5000/getAToken
  &scope=openid profile
  &state=3a7f2c9d-8b1e-4f6a-9c2d-5e8f1a3b7c9d
```

### Step 4: Redirect User to Microsoft

```python
    return redirect(auth_url)
```
- Sends HTTP 302 redirect response to browser
- Browser automatically navigates to `auth_url` (Microsoft's login page)
- **User is now on Microsoft's website** - no longer on your app
- **Flask function ends here** - execution stops, waiting for user to return

**What user sees:** Microsoft login page asking for username and password

---

## Authorization Callback Route (/getAToken)

After the user logs in at Microsoft, Microsoft redirects the browser back to your app at this route with the authorization code.

```python
@app.route(app_config.REDIRECT_PATH)  # Default: /getAToken
def authorized():
    """Handle the redirect from Entra ID after authentication"""
```
- `app_config.REDIRECT_PATH` is `"/getAToken"`
- This function runs when Microsoft sends the user back
- URL will look like: `http://localhost:5000/getAToken?code=ABC123...&state=3a7f2c9d...`

### Step 1: Verify State (CSRF Protection)

```python
    if request.args.get('state') != session.get("state"):
        return redirect(url_for("index"))
```
- `request.args.get('state')` - Gets the `state` parameter from URL (sent by Microsoft)
- `session.get("state")` - Gets the state we stored earlier in THIS user's session
- `!=` - Checks if they DON'T match
- **If mismatch:** Possible attack! Redirect to home page without logging in
- **If match:** Continue - we know this request legitimately came from Microsoft for this user

### Step 2: Check for Authorization Code

```python
    if "code" in request.args:
```
- `request.args` - Dictionary of URL parameters
- `"code" in request.args` - Checks if Microsoft sent an authorization code
- **If no code:** User probably cancelled login or there was an error
- **If code exists:** Continue with authentication

### Step 3: Load Token Cache

```python
        cache = _load_cache()
```
- Calls helper function that:
  - Creates an empty `msal.SerializableTokenCache()` object
  - Checks if `session["token_cache"]` exists (from previous login)
  - If exists, loads the cached tokens into the cache object
- **For new user:** Cache is empty
- **For returning user:** Cache contains previous tokens (though for new login, we'll get fresh ones)

### Step 4: Build MSAL App with Cache

```python
        auth_app = _build_msal_app(cache=cache)
```
- Creates MSAL app object again, this time with the cache
- Cache will be updated with new tokens we're about to receive

### Step 5: Exchange Code for Tokens

```python
        result = auth_app.acquire_token_by_authorization_code(
            request.args['code'],
            scopes=app_config.SCOPE,
            redirect_uri=url_for("authorized", _external=True)
        )
```

**This is the critical step!**

**Parameters:**
- `request.args['code']` - The one-time authorization code from Microsoft
- `scopes=app_config.SCOPE` - Same scopes we requested
- `redirect_uri` - Same redirect URI (must match exactly)

**What happens behind the scenes:**
1. MSAL makes a **server-to-server HTTP POST request** to Microsoft
2. Sends the authorization code
3. Sends your `CLIENT_ID` and `CLIENT_SECRET` (proves your app is legitimate)
4. Microsoft validates everything
5. Microsoft responds with a JSON object containing:
   - **ID Token** - JWT (JSON Web Token) with user's identity (name, email, user ID)
   - **Access Token** - Can be used to call Microsoft APIs (if you requested scopes)
   - **Refresh Token** - Can get new access tokens without user re-logging in

**Result dictionary contains:**
```python
{
    "id_token_claims": {
        "name": "John Doe",
        "preferred_username": "john@company.com",
        "oid": "user-object-id-guid",
        "tid": "tenant-id-guid",
        # ... other claims
    },
    "access_token": "eyJ0eXAi...",
    "refresh_token": "0.AXoA...",
    "expires_in": 3599
}
```

### Step 6: Handle Errors

```python
        if "error" in result:
            return render_template("auth_error.html", result=result)
```
- If token exchange failed, `result` contains `"error"` key
- Display error page to user
- **Common errors:** Invalid code, expired code, mismatched redirect_uri

### Step 7: Store User Info in Session

```python
        session["user"] = result.get("id_token_claims")
```
- `result.get("id_token_claims")` - Extracts the user information from the ID token
- `session["user"] = ...` - Stores it in the user's session
- **This is what makes them "logged in"**
- Session is automatically saved to disk in `flask_session/` directory
- Next time user visits, `session.get("user")` will return this data

### Step 8: Save Token Cache

```python
        _save_cache(cache)
```
- Saves the tokens (access token, refresh token, etc.) to the session
- Stored as `session["token_cache"]` (serialized format)
- **Why:** Can use tokens later to call Microsoft APIs or refresh expired tokens

### Step 9: Redirect to Home Page

```python
    return redirect(url_for("index"))
```
- Sends user back to home page (`/`)
- Now `session.get("user")` returns user info
- Home page displays "Welcome, John Doe!" with logout button
- **User is now logged in!**

---

## Logout Route (/logout)

```python
@app.route("/logout")
def logout():
```

### Step 1: Clear Local Session

```python
    session.clear()
```
- Removes ALL data from the user's session dictionary
- Deletes `session["user"]`, `session["token_cache"]`, `session["state"]`
- Session file in `flask_session/` is cleared
- **User is now logged out locally**

### Step 2: Redirect to Microsoft Logout

```python
    return redirect(
        app_config.AUTHORITY + "/oauth2/v2.0/logout" +
        "?post_logout_redirect_uri=" + url_for("index", _external=True)
    )
```

**URL breakdown:**
- `app_config.AUTHORITY` = `"https://login.microsoftonline.com/{TENANT_ID}"`
- `+ "/oauth2/v2.0/logout"` = Microsoft's logout endpoint
- `+ "?post_logout_redirect_uri=..."` = Where to send user after logout
- `url_for("index", _external=True)` = `"http://localhost:5000/"` (your home page)

**Result:** Browser goes to:
```
https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/logout?post_logout_redirect_uri=http://localhost:5000/
```

**What happens:**
1. Microsoft clears the user's Entra ID session (logout from Microsoft side)
2. Microsoft redirects browser back to your home page
3. User is now fully logged out both locally and from Microsoft
4. **Why needed:** Without this, user might appear logged out on your app but still logged in at Microsoft
   - Could cause confusion on next login (auto-logs in without password prompt)

---

## Helper Functions

### _load_cache()

```python
def _load_cache():
    """Load token cache from session"""
    cache = msal.SerializableTokenCache()
    if session.get("token_cache"):
        cache.deserialize(session["token_cache"])
    return cache
```

**Line-by-line:**
- `cache = msal.SerializableTokenCache()` - Creates an empty token cache object
- `if session.get("token_cache"):` - Checks if we've saved tokens before
- `cache.deserialize(session["token_cache"])` - Loads the saved tokens into the cache
  - `session["token_cache"]` is a string (serialized JSON)
  - `deserialize()` converts it back to usable token objects
- `return cache` - Returns the cache (either empty or with loaded tokens)

**Purpose:** Retrieve previously saved access tokens, refresh tokens, etc.

### _save_cache(cache)

```python
def _save_cache(cache):
    """Save token cache to session"""
    if cache.has_state_changed:
        session["token_cache"] = cache.serialize()
```

**Line-by-line:**
- `if cache.has_state_changed:` - Only save if tokens were added/updated
  - Avoids unnecessary writes
- `cache.serialize()` - Converts cache to a JSON string
- `session["token_cache"] = ...` - Stores in session
  - Automatically saved to `flask_session/` directory
  - Survives app restarts

**Purpose:** Persist tokens so user doesn't need to re-authenticate every request

### _build_msal_app(cache=None, authority=None)

```python
def _build_msal_app(cache=None, authority=None):
    """Build a ConfidentialClientApplication instance"""
    return msal.ConfidentialClientApplication(
        app_config.CLIENT_ID,
        authority=authority or app_config.AUTHORITY,
        client_credential=app_config.CLIENT_SECRET,
        token_cache=cache
    )
```

**Parameters:**
- `cache=None` - Optional token cache (defaults to None)
- `authority=None` - Optional authority URL (defaults to app_config.AUTHORITY)

**Returns:** MSAL `ConfidentialClientApplication` object with:

- `app_config.CLIENT_ID` - Your application's unique ID from Azure
  - Example: `"12345678-1234-1234-1234-123456789abc"`
- `authority or app_config.AUTHORITY` - Microsoft login URL
  - Example: `"https://login.microsoftonline.com/abcd-tenant-id-1234"`
- `client_credential=app_config.CLIENT_SECRET` - Your app's secret password
  - Proves your app is legitimate when talking to Microsoft
  - **"Confidential"** means app can securely store this secret (server-side apps)
- `token_cache=cache` - Where to store/retrieve tokens

**Purpose:** Creates an object that can:
- Generate authorization URLs
- Exchange authorization codes for tokens
- Refresh expired tokens
- Manage token lifecycle

### _get_token_from_cache(scope=None)

```python
def _get_token_from_cache(scope=None):
    """Attempt to retrieve a token from the cache"""
    cache = _load_cache()
    auth_app = _build_msal_app(cache=cache)
    
    accounts = auth_app.get_accounts()
    if accounts:
        result = auth_app.acquire_token_silent(scope, account=accounts[0])
        _save_cache(cache)
        return result
    
    return None
```

**Line-by-line:**
- `cache = _load_cache()` - Load previously saved tokens
- `auth_app = _build_msal_app(cache=cache)` - Create MSAL app with cache
- `accounts = auth_app.get_accounts()` - Get list of cached user accounts
  - Returns list of users who have logged in before
- `if accounts:` - If we found at least one account
- `result = auth_app.acquire_token_silent(scope, account=accounts[0])` - Try to get token WITHOUT user interaction
  - Uses cached access token if still valid
  - Uses refresh token to get new access token if expired
  - Returns tokens OR `None` if can't silently acquire
- `_save_cache(cache)` - Save any updated tokens
- `return result` - Return the tokens
- `return None` - No cached accounts found

**Purpose:** Get access tokens without asking user to log in again
- Used when calling Microsoft APIs
- Not used in this simple sign-in app, but available for future use

---

## Complete Authentication Flow

### New User Login Flow (Step-by-Step)

1. **User visits home page (`/`)**
   - `session.get("user")` returns `None`
   - Page shows "Sign In" button

2. **User clicks "Sign In" button**
   - Browser navigates to `/login`

3. **`/login` route executes:**
   - Generates random state: `session["state"] = "abc-123-xyz"`
   - Creates MSAL app object
   - Builds Microsoft login URL with state and redirect URI
   - Redirects browser to Microsoft

4. **User is now on Microsoft's login page**
   - Enters username and password
   - Microsoft authenticates the user
   - Microsoft generates one-time authorization code

5. **Microsoft redirects back to your app**
   - Browser goes to: `/getAToken?code=XYZ789&state=abc-123-xyz`

6. **`/getAToken` route executes:**
   - Verifies state matches: `session["state"] == "abc-123-xyz"` ✓
   - Extracts authorization code from URL
   - Makes server-to-server call to Microsoft
   - Exchanges code for tokens (ID token, access token, refresh token)
   - Stores user info: `session["user"] = {name, email, ...}`
   - Saves tokens: `session["token_cache"] = {...}`
   - Redirects to home page

7. **User is back on home page (`/`)**
   - `session.get("user")` returns user info
   - Page shows "Welcome, John Doe!" and "Sign Out" button
   - **User is logged in!**

### Returning User (After App Restart)

1. **User visits home page**
   - Browser sends session cookie
   - Flask loads session from `flask_session/` directory
   - `session.get("user")` returns previously stored user info
   - **User appears logged in automatically** - no login required!

### Logout Flow

1. **User clicks "Sign Out"**
   - Browser navigates to `/logout`

2. **`/logout` route executes:**
   - `session.clear()` - Removes all session data
   - Redirects to Microsoft logout endpoint

3. **Microsoft clears Entra ID session**
   - User is logged out from Microsoft
   - Browser redirected back to home page

4. **User is back on home page**
   - `session.get("user")` returns `None`
   - Page shows "Sign In" button
   - **User is logged out!**

---

## Key Concepts Explained

### OAuth 2.0 Authorization Code Flow

This is the **most secure** OAuth flow for web applications:

1. **Authorization Request** - App redirects user to Microsoft login
2. **User Authentication** - User logs in at Microsoft (NOT on your app)
3. **Authorization Code** - Microsoft gives your app a one-time code
4. **Token Exchange** - Your app exchanges code + secret for tokens (server-to-server)
5. **Access Resources** - Your app uses tokens to identify user or call APIs

**Why secure?**
- User's password never goes to your app
- Authorization code is one-time use only
- Token exchange requires CLIENT_SECRET (only your server knows this)
- Attackers can't intercept and reuse codes

### MSAL (Microsoft Authentication Library)

- **What it is:** A library that implements OAuth 2.0 protocol for Microsoft services
- **What it does:**
  - Builds properly formatted authorization URLs
  - Exchanges codes for tokens
  - Manages token expiration and refresh
  - Caches tokens efficiently
  - Handles all the complex OAuth details

**ConfidentialClientApplication** vs **PublicClientApplication:**
- **Confidential** - Server-side apps that can keep CLIENT_SECRET secure (like this Flask app)
- **Public** - Client-side apps (JavaScript SPAs, mobile apps) that can't keep secrets

### Sessions and Persistence

**Flask Session:**
- Dictionary-like object: `session["key"] = "value"`
- Automatically saved to disk (`flask_session/` directory)
- Each user gets separate session file
- Browser gets session cookie to identify which session is theirs

**Session Cookie:**
- Small piece of data stored in browser
- Contains session ID (like a key to unlock your session file)
- Sent automatically with every request
- Flask uses it to load the correct session

**Persistence:**
- Sessions survive app restarts (saved to disk)
- Users stay logged in even if you restart Flask
- To fully clear: delete `flask_session/` directory OR user clicks logout

### Tokens Explained

**ID Token:**
- Contains user's identity information (name, email, user ID)
- JWT (JSON Web Token) format
- Used to know WHO the user is
- **This app uses ID token to display user info**

**Access Token:**
- Used to call Microsoft APIs (Graph API, etc.)
- Has an expiration time (usually 1 hour)
- Can request specific permissions (scopes)
- **This app doesn't use access tokens (no API calls)**

**Refresh Token:**
- Used to get new access tokens when they expire
- Long-lived (days/weeks)
- Avoids asking user to log in again
- **Automatically used by MSAL when needed**

### Security Features

**CSRF Protection (State Parameter):**
- Random value stored in session and sent to Microsoft
- Microsoft echoes it back
- We verify they match
- **Prevents:** Attacker tricking user into logging in with attacker's account

**HTTPS in Production:**
- All tokens sent over encrypted connection
- Prevents man-in-the-middle attacks
- **Required** for production apps

**Client Secret:**
- Proves your app's identity to Microsoft
- Must be kept secure (server-side only)
- Never expose in client-side code or version control
- **Use environment variables** for production

---

## Common Questions

**Q: Why does the user stay logged in after restarting the Flask app?**

A: Sessions are stored on disk in `flask_session/` directory, not in memory. When Flask restarts, it reloads the session from disk using the session cookie.

**Q: Can multiple users be logged in at the same time?**

A: Yes! Each user gets their own session file. The session cookie tells Flask which session belongs to which user.

**Q: What if someone steals the session cookie?**

A: They can impersonate the user until:
- Session expires
- User logs out
- Session is invalidated
- Use `SESSION_COOKIE_SECURE=True` and `SESSION_COOKIE_HTTPONLY=True` in production to reduce risk

**Q: How long do sessions last?**

A: By default, until user logs out or clears browser cookies. You can set `PERMANENT_SESSION_LIFETIME` in config to auto-expire sessions.

**Q: What's the difference between logging out locally vs from Microsoft?**

A: 
- **Local logout** (`session.clear()`) - User logged out from your app only
- **Microsoft logout** - User logged out from Entra ID entirely
- **Both needed** for complete logout experience

**Q: Can I use this same flow for mobile apps?**

A: No, mobile apps should use PKCE (Proof Key for Code Exchange) flow with `PublicClientApplication` since they can't securely store CLIENT_SECRET.

---

## Summary

This Flask app implements the OAuth 2.0 Authorization Code Flow:

1. User clicks "Sign In" → redirected to Microsoft
2. User logs in at Microsoft
3. Microsoft sends authorization code back to app
4. App exchanges code + secret for tokens
5. App stores user info in session
6. User is logged in!

**Key components:**
- **Flask** - Web framework
- **Flask-Session** - Server-side session storage
- **MSAL** - Microsoft authentication library
- **OAuth 2.0** - Authorization protocol
- **Entra ID** - Microsoft's identity service

**Security features:**
- CSRF protection (state parameter)
- Client secret for server authentication
- One-time authorization codes
- Server-side session storage
- HTTPS required for production
