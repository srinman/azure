# Step-by-Step Program Explanation: Protected API (Scenario 2)

This document provides a detailed line-by-line explanation of how the protected API validates OAuth 2.0 access tokens from Entra ID.

---

## Table of Contents
1. [Overview](#overview)
2. [Imports and Configuration](#imports-and-configuration)
3. [JWT Token Validation Basics](#jwt-token-validation-basics)
4. [validate_token Decorator](#validate_token-decorator)
5. [API Endpoints](#api-endpoints)
6. [Complete Token Validation Flow](#complete-token-validation-flow)
7. [Understanding JWT Structure](#understanding-jwt-structure)
8. [Security Deep Dive](#security-deep-dive)

---

## Overview

This is a **protected API** that:
- Accepts HTTP requests with Bearer tokens
- Validates OAuth 2.0 access tokens from Entra ID
- Returns token claims if valid
- Rejects invalid/expired tokens with 401 error

**Key capabilities:**
- JWT (JSON Web Token) validation
- Cryptographic signature verification
- Audience and issuer validation
- Automatic public key fetching from Microsoft
- Claims extraction and return

---

## Imports and Configuration

```python
from flask import Flask, jsonify, request
from functools import wraps
import jwt
from jwt import PyJWKClient
import os
```

**Line-by-line:**

- `from flask import Flask, jsonify, request`
  - `Flask` - Web framework
  - `jsonify` - Converts Python dict to JSON response
  - `request` - Access to incoming HTTP request (headers, body, etc.)

- `from functools import wraps`
  - `wraps` - Preserves function metadata when creating decorators
  - Required for decorator pattern

- `import jwt`
  - PyJWT library for validating JSON Web Tokens
  - Handles cryptographic signature verification
  - Decodes token claims

- `from jwt import PyJWKClient`
  - Client for fetching public keys from JWKS (JSON Web Key Set) endpoint
  - Microsoft publishes public keys used to sign tokens
  - Auto-fetches and caches keys

- `import os`
  - Access environment variables for configuration

### Configuration

```python
app = Flask(__name__)

# Configuration from environment variables
TENANT_ID = os.getenv("TENANT_ID", "YOUR_TENANT_ID")
CLIENT_ID = os.getenv("API_CLIENT_ID", "YOUR_API_CLIENT_ID")
```

**Line-by-line:**
- `TENANT_ID` - Your Azure tenant ID (organization)
  - Used to validate token issuer
  - Ensures token came from your organization's Entra ID
- `CLIENT_ID` - This API's application ID
  - Used to validate token audience
  - Ensures token was meant for THIS API

```python
# Valid audiences - tokens can have either format
VALID_AUDIENCES = [
    CLIENT_ID,
    f"api://{CLIENT_ID}"
]
```

**Why two formats?**

Microsoft access tokens can have different audience formats:

1. **Just the GUID:** `"12345678-1234-1234-1234-123456789abc"`
   - Older format
   - Just the application ID

2. **Application ID URI:** `"api://12345678-1234-1234-1234-123456789abc"`
   - Newer recommended format
   - Clearer that it's an API resource

**Both are valid** - we accept either to handle different token versions

### JWKS Endpoint Setup

```python
# Microsoft signing keys endpoint
JWKS_URI = f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys"

# Initialize PyJWKClient for automatic key fetching and caching
jwks_client = PyJWKClient(JWKS_URI)
```

**Line-by-line:**

- `JWKS_URI` - URL where Microsoft publishes public keys
  - Example: `https://login.microsoftonline.com/abc-tenant-123/discovery/v2.0/keys`
  - Returns JSON with multiple public keys
  - Keys rotate periodically for security

- `jwks_client = PyJWKClient(JWKS_URI)`
  - Creates client that fetches keys from JWKS endpoint
  - **Automatically caches keys** - doesn't fetch on every request
  - **Auto-refreshes** - when token uses new key, fetches it
  - **Thread-safe** - can handle concurrent requests

**What are JWKS?**
- **J**SON **W**eb **K**ey **S**et
- Standard way to publish public keys for JWT verification
- Microsoft signs tokens with private key, publishes public key for verification

---

## JWT Token Validation Basics

### What is a JWT?

A **JWT (JSON Web Token)** is a three-part string separated by dots:

```
{header}.{payload}.{signature}
```

**Example token:**
```
eyJ0eXAiOiJKV1QiLCJhbGc.eyJhdWQiOiJhcGk6Ly8xMjM.SflKxwRJSMeKKF2QT4fwpM
```

**Parts:**
1. **Header** - Token metadata (algorithm, key ID)
2. **Payload** - Claims (audience, issuer, user info, expiration)
3. **Signature** - Cryptographic signature proving authenticity

### How JWT Validation Works

1. **Decode header** - Find which key was used to sign token (key ID)
2. **Fetch public key** - Get corresponding public key from JWKS
3. **Verify signature** - Cryptographically verify token wasn't tampered with
4. **Check expiration** - Ensure token hasn't expired
5. **Validate audience** - Ensure token meant for this API
6. **Validate issuer** - Ensure token from trusted Entra ID
7. **Extract claims** - Get user info and permissions from payload

---

## validate_token Decorator

This is a **decorator** that wraps endpoint functions to require valid tokens.

```python
def validate_token(f):
    """Decorator to validate access token"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
```

**Decorator pattern explanation:**

Instead of writing validation logic in every endpoint:
```python
@app.route("/api/claims")
def get_claims():
    # Validate token code here...
    # Actual endpoint logic here...
```

We use a decorator:
```python
@app.route("/api/claims")
@validate_token  # <-- Decorator handles validation
def get_claims():
    # Just the endpoint logic - token already validated!
```

**Line-by-line:**
- `def validate_token(f):` - Decorator function, `f` is the endpoint function
- `@wraps(f)` - Preserves original function's name and docstring
- `def decorated_function(*args, **kwargs):` - Wrapper that runs before endpoint

### Step 1: Extract Token from Header

```python
        # Get token from Authorization header
        auth_header = request.headers.get('Authorization', '')
        
        if not auth_header.startswith('Bearer '):
            return jsonify({"error": "Missing or invalid Authorization header"}), 401
        
        token = auth_header.split(' ')[1]
```

**Line-by-line:**

- `request.headers.get('Authorization', '')` - Get Authorization header
  - Returns empty string if header missing
  - Example header: `"Bearer eyJ0eXAiOiJKV1QiLCJh..."`

- `if not auth_header.startswith('Bearer '):` - Validate format
  - Must start with "Bearer " (note the space)
  - Standard OAuth 2.0 format

- `return jsonify(...), 401` - Return error if invalid
  - `401` = Unauthorized HTTP status code
  - Returns JSON: `{"error": "Missing or invalid Authorization header"}`

- `token = auth_header.split(' ')[1]` - Extract token
  - Splits on space: `["Bearer", "eyJ0eXAiOiJKV1Q..."]`
  - Takes second part `[1]` - the actual token
  - Result: `"eyJ0eXAiOiJKV1Q..."`

### Step 2: Get Signing Key

```python
        try:
            # Get the signing key from the token's header
            signing_key = jwks_client.get_signing_key_from_jwt(token)
```

**What happens here:**

1. **PyJWKClient decodes token header** (without validating yet)
2. **Reads the `kid` (Key ID)** from header
   - Example: `"kid": "abc123"`
3. **Fetches JWKS from Microsoft** (or uses cached version)
4. **Finds matching key** with same `kid`
5. **Returns signing key** in PEM format for verification

**Example JWKS response from Microsoft:**
```json
{
  "keys": [
    {
      "kid": "abc123",
      "kty": "RSA",
      "use": "sig",
      "n": "long-base64-modulus",
      "e": "AQAB"
    }
  ]
}
```

**Why automatic key fetching is important:**
- Microsoft rotates keys periodically
- Token might use new key we don't have cached
- PyJWKClient automatically fetches new keys as needed
- No manual key management required

### Step 3: Decode and Validate Token

```python
            # Validate and decode token
            payload = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256"],
                options={"verify_aud": False, "verify_iss": False}
            )
```

**Parameters explained:**

- `token` - The JWT string to validate
- `signing_key.key` - Public key for signature verification (PEM format)
- `algorithms=["RS256"]` - Only accept RS256 algorithm
  - **RS256** = RSA Signature with SHA-256
  - Asymmetric encryption (public/private key pair)
  - Most secure and common for Microsoft tokens
- `options={"verify_aud": False, "verify_iss": False}` - Skip automatic validation
  - **Why?** We do manual validation to support multiple audience/issuer formats
  - PyJWT's automatic validation is too strict for Microsoft's multiple formats

**What `jwt.decode()` does:**

1. **Verify signature** - Uses public key to verify token wasn't tampered with
2. **Check expiration** - Validates `exp` claim (automatic)
3. **Check not-before** - Validates `nbf` claim (automatic)
4. **Decode payload** - Extracts all claims into Python dictionary
5. **Return claims** - Dictionary with user info, permissions, etc.

**If validation fails, raises exceptions:**
- `jwt.ExpiredSignatureError` - Token expired
- `jwt.InvalidTokenError` - Bad signature, malformed token, etc.

### Step 4: Manual Audience Validation

```python
            # Manually validate audience
            if payload.get("aud") not in VALID_AUDIENCES:
                return jsonify({"error": f"Invalid audience: {payload.get('aud')}. Expected one of: {VALID_AUDIENCES}"}), 401
```

**Line-by-line:**

- `payload.get("aud")` - Get audience claim from token
  - Example: `"api://12345-api-guid"` or `"12345-api-guid"`
- `not in VALID_AUDIENCES` - Check if audience matches expected values
- **If mismatch:** Token meant for different API, reject with 401

**Why validate audience?**
- Prevents token substitution attacks
- Token for API A shouldn't work on API B
- Even if signature valid, must be intended for THIS API

**Example attack without audience validation:**
1. Attacker gets valid token for "API A"
2. Tries to use same token on "API B"
3. Without audience check, API B would accept it
4. With audience check, API B rejects it ✅

### Step 5: Manual Issuer Validation

```python
            # Manually validate issuer
            valid_issuers = [
                f"https://sts.windows.net/{TENANT_ID}/",
                f"https://login.microsoftonline.com/{TENANT_ID}/v2.0",
                f"https://login.microsoftonline.com/{TENANT_ID}/"
            ]
            
            if payload.get("iss") not in valid_issuers:
                return jsonify({"error": f"Invalid issuer: {payload.get('iss')}"}), 401
```

**Why multiple issuer formats?**

Microsoft Entra ID can issue tokens with different issuer values:

1. **`https://sts.windows.net/{TENANT_ID}/`**
   - Older v1 endpoint format
   - "STS" = Security Token Service

2. **`https://login.microsoftonline.com/{TENANT_ID}/v2.0`**
   - v2 endpoint format
   - Modern, recommended

3. **`https://login.microsoftonline.com/{TENANT_ID}/`**
   - Alternative format

**All are valid** - depends on which endpoint issued the token

**Line-by-line:**
- `payload.get("iss")` - Get issuer claim from token
- `not in valid_issuers` - Check if issuer is from our tenant
- **If mismatch:** Token from different tenant or unauthorized source, reject

**Why validate issuer?**
- Ensures token came from trusted Entra ID
- Prevents tokens from other organizations
- Prevents tokens from fake/malicious issuers

### Step 6: Store Claims in Request Context

```python
            # Store claims in request context
            request.token_claims = payload
```

- Attaches claims to Flask's `request` object
- Endpoint functions can access via `request.token_claims`
- Only available for this request (thread-safe)

### Step 7: Exception Handling

```python
        except jwt.ExpiredSignatureError:
            return jsonify({"error": "Token has expired"}), 401
        except jwt.InvalidTokenError as e:
            return jsonify({"error": f"Invalid token: {str(e)}"}), 401
        except Exception as e:
            return jsonify({"error": f"Token validation failed: {str(e)}"}), 401
```

**Different error types:**

1. **`jwt.ExpiredSignatureError`**
   - Token's `exp` claim in the past
   - Client should get new token

2. **`jwt.InvalidTokenError`**
   - Bad signature (token tampered with)
   - Malformed token
   - Wrong algorithm

3. **`Exception`** (catch-all)
   - Network error fetching JWKS
   - Unexpected validation error

**All return 401 Unauthorized** - appropriate for authentication failures

### Step 8: Call Original Endpoint

```python
        return f(*args, **kwargs)
    
    return decorated_function
```

- `return f(*args, **kwargs)` - Call the original endpoint function
- Only reaches here if token valid
- Endpoint has access to `request.token_claims`

---

## API Endpoints

### Public Info Endpoint (/)

```python
@app.route("/")
def index():
    """API info endpoint (no authentication required)"""
    return jsonify({
        "name": "Protected Claims API",
        "version": "1.0",
        "endpoints": {
            "/": "This info page (public)",
            "/api/claims": "Returns token claims (requires authentication)"
        },
        "authentication": "Bearer token required for /api/claims"
    })
```

**Purpose:** Public endpoint showing API information

**No authentication** - No `@validate_token` decorator

**Returns:** JSON with API documentation

**Use case:** Health check, API discovery, testing endpoint is running

### Protected Claims Endpoint (/api/claims)

```python
@app.route("/api/claims")
@validate_token
def get_claims():
    """
    Protected endpoint - Returns all claims from the access token
    Requires valid Entra ID access token in Authorization header
    """
    claims = request.token_claims
```

**Line-by-line:**

- `@app.route("/api/claims")` - Maps URL to function
- `@validate_token` - **Requires valid token** - decorator validates before function runs
- `claims = request.token_claims` - Get claims stored by decorator
  - Already validated
  - Safe to use

```python
    return jsonify({
        "message": "Successfully validated token",
        "claims": {
            "aud": claims.get("aud", ""),  # Audience (API Client ID)
            "iss": claims.get("iss", ""),  # Issuer
            "iat": claims.get("iat", ""),  # Issued at
            "nbf": claims.get("nbf", ""),  # Not before
            "exp": claims.get("exp", ""),  # Expiration
            "name": claims.get("name", ""),  # User's name
            "preferred_username": claims.get("preferred_username", ""),  # Email
            "oid": claims.get("oid", ""),  # Object ID
            "tid": claims.get("tid", ""),  # Tenant ID
            "scp": claims.get("scp", ""),  # Scopes
            "appid": claims.get("appid", ""),  # Application ID making the call
            "ver": claims.get("ver", ""),  # Token version
        },
        "all_claims": claims  # Return everything for debugging
    })
```

**Claims explained:**

- **`aud` (Audience)** - Who the token is for
  - Example: `"api://12345-api-guid"`
  - Should match this API's CLIENT_ID

- **`iss` (Issuer)** - Who issued the token
  - Example: `"https://login.microsoftonline.com/{tenant}/v2.0"`
  - Should be Microsoft Entra ID for your tenant

- **`iat` (Issued At)** - When token was created
  - Unix timestamp: `1699372800`
  - Example: November 7, 2023, 12:00:00 PM

- **`nbf` (Not Before)** - Token not valid before this time
  - Usually same as `iat`
  - Prevents clock skew issues

- **`exp` (Expiration)** - When token expires
  - Unix timestamp: `1699376400`
  - Usually 1 hour after `iat`

- **`name`** - User's display name
  - Example: `"John Doe"`

- **`preferred_username`** - User's email
  - Example: `"john@company.com"`

- **`oid` (Object ID)** - User's unique ID in Entra ID
  - GUID: `"12345678-user-guid"`
  - Never changes, stable identifier

- **`tid` (Tenant ID)** - Organization's unique ID
  - GUID: `"87654321-tenant-guid"`

- **`scp` (Scopes)** - Permissions granted
  - Example: `"access_as_user"`
  - Space-separated if multiple: `"read write"`

- **`appid` (Application ID)** - Client app making the request
  - Web app's CLIENT_ID
  - Example: `"abcdef-webapp-guid"`

- **`ver` (Version)** - Token version
  - `"1.0"` or `"2.0"`
  - Affects token format

### Health Check Endpoint (/health)

```python
@app.route("/health")
def health():
    """Health check endpoint"""
    return jsonify({"status": "healthy"}), 200
```

**Purpose:** Simple endpoint for monitoring/load balancers

**No authentication required**

**Returns:** `{"status": "healthy"}` with 200 OK

---

## Complete Token Validation Flow

### Successful Request Flow

1. **Web app calls API**
   ```
   GET /api/claims
   Authorization: Bearer eyJ0eXAiOiJKV1Q...
   ```

2. **API receives request**
   - Flask routes to `get_claims()` function
   - But `@validate_token` decorator intercepts first

3. **Decorator extracts token**
   - Gets `Authorization` header
   - Validates format starts with "Bearer "
   - Extracts token string

4. **Fetch signing key**
   - PyJWKClient reads token header
   - Gets `kid` (key ID)
   - Fetches matching public key from Microsoft JWKS

5. **Validate signature**
   - Uses public key to verify signature
   - Ensures token not tampered with

6. **Check expiration**
   - PyJWT automatically validates `exp` claim
   - Rejects if current time > expiration

7. **Validate audience**
   - Checks `aud` claim matches API's CLIENT_ID
   - Ensures token meant for this API

8. **Validate issuer**
   - Checks `iss` claim is from trusted Entra ID
   - Ensures token from our tenant

9. **Store claims**
   - Attaches claims to `request.token_claims`

10. **Call endpoint**
    - Decorator passes control to `get_claims()`
    - Endpoint accesses `request.token_claims`
    - Returns claims to caller

11. **Web app receives response**
    - JSON with all token claims
    - Displays to user

### Failed Request Flow (Invalid Token)

1. **Attacker calls API with fake token**
   ```
   GET /api/claims
   Authorization: Bearer fake-token-abc123
   ```

2. **Decorator extracts token**
   - Token: `"fake-token-abc123"`

3. **Attempt to fetch signing key**
   - PyJWKClient tries to decode header
   - **FAILS** - Not valid JWT format

4. **Exception raised**
   - `jwt.InvalidTokenError`

5. **Decorator catches exception**
   - Returns error response:
   ```json
   {
     "error": "Invalid token: ..."
   }
   ```
   - HTTP status 401 Unauthorized

6. **Endpoint never called**
   - `get_claims()` never executes
   - No access to protected data

### Expired Token Flow

1. **Web app calls API with old token**
   - Token has `exp: 1699372800` (past time)

2. **Decorator validates signature** ✅
   - Signature valid

3. **PyJWT checks expiration** ❌
   - Current time > `exp`
   - Raises `jwt.ExpiredSignatureError`

4. **Decorator catches exception**
   - Returns: `{"error": "Token has expired"}`
   - HTTP 401

5. **Web app should refresh token**
   - Uses `acquire_token_silent()` to get new token
   - Retries API call with fresh token

---

## Understanding JWT Structure

### Example Access Token

```
eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsImtpZCI6ImFiYzEyMyJ9.
eyJhdWQiOiJhcGk6Ly8xMjM0NTY3OC1hcGktZ3VpZCIsImlzcyI6Imh0dHBzOi8vbG9naW4ubWljcm9zb2Z0b25saW5lLmNvbS90ZW5hbnQtaWQvdjIuMCIsImlhdCI6MTY5OTM3MjgwMCwibmJmIjoxNjk5MzcyODAwLCJleHAiOjE2OTkzNzY0MDAsIm5hbWUiOiJKb2huIERvZSIsInByZWZlcnJlZF91c2VybmFtZSI6ImpvaG5AY29tcGFueS5jb20iLCJvaWQiOiJ1c2VyLWd1aWQiLCJ0aWQiOiJ0ZW5hbnQtZ3VpZCIsInNjcCI6ImFjY2Vzc19hc191c2VyIiwiYXBwaWQiOiJ3ZWJhcHAtZ3VpZCIsInZlciI6IjIuMCJ9.
signature-base64-encoded
```

### Decoded Header

```json
{
  "typ": "JWT",
  "alg": "RS256",
  "kid": "abc123"
}
```

- `typ` - Type: JWT
- `alg` - Algorithm: RS256 (RSA with SHA-256)
- `kid` - Key ID: which key Microsoft used to sign

### Decoded Payload (Claims)

```json
{
  "aud": "api://12345678-api-guid",
  "iss": "https://login.microsoftonline.com/tenant-id/v2.0",
  "iat": 1699372800,
  "nbf": 1699372800,
  "exp": 1699376400,
  "name": "John Doe",
  "preferred_username": "john@company.com",
  "oid": "user-guid",
  "tid": "tenant-guid",
  "scp": "access_as_user",
  "appid": "webapp-guid",
  "ver": "2.0"
}
```

### Signature

- Base64-encoded cryptographic signature
- Generated using Microsoft's private key
- Verified using Microsoft's public key (from JWKS)
- Ensures payload wasn't modified

**Signature process:**
1. Microsoft creates: `signature = RSA_sign(header + payload, private_key)`
2. API verifies: `RSA_verify(signature, header + payload, public_key)`
3. If verification succeeds, token is authentic

---

## Security Deep Dive

### Why Signature Verification is Critical

**Without signature verification:**
- Attacker could create fake token with any claims
- Could impersonate any user
- Could claim any permissions

**With signature verification:**
- Only Microsoft can create valid tokens (has private key)
- Any modification breaks signature
- API rejects modified tokens

### Asymmetric Cryptography Explained

**Microsoft has:**
- **Private key** - Secret, never shared
- Used to SIGN tokens

**API has:**
- **Public key** - Published at JWKS endpoint
- Used to VERIFY tokens

**Properties:**
- Can't derive private key from public key
- Can verify signatures without private key
- Only holder of private key can create valid signatures

### Attack Scenarios Prevented

#### 1. Token Tampering

**Attack:**
1. Attacker gets valid token
2. Changes `scp` from `"read"` to `"admin"`
3. Sends modified token to API

**Defense:**
- Signature verification fails (payload changed)
- API rejects token with 401

#### 2. Token Replay on Wrong API

**Attack:**
1. Attacker gets token for "API A"
2. Sends same token to "API B"

**Defense:**
- Audience validation fails (`aud` doesn't match API B's CLIENT_ID)
- API B rejects token with 401

#### 3. Token from Different Tenant

**Attack:**
1. Attacker gets token from their own tenant
2. Tries to use on your API

**Defense:**
- Issuer validation fails (different TENANT_ID)
- API rejects token with 401

#### 4. Expired Token

**Attack:**
1. Attacker uses old, expired token

**Defense:**
- Expiration check fails (current time > `exp`)
- API rejects token with 401

#### 5. Forged Token

**Attack:**
1. Attacker creates fake token with fake signature

**Defense:**
- Signature verification fails (not signed by Microsoft)
- API rejects token with 401

### Key Rotation

**Why keys rotate:**
- Security best practice
- Limits impact if private key compromised
- Microsoft rotates periodically

**How API handles:**
- PyJWKClient automatically fetches new keys
- Caches keys for performance
- Refetches when token uses unknown `kid`
- No manual intervention required

### HTTPS Requirement

**Why HTTPS is critical:**
- Access tokens transmitted in HTTP headers
- Without HTTPS, tokens visible to network eavesdroppers
- Attacker on network could steal token and impersonate user

**In production:**
- **ALWAYS use HTTPS** for APIs
- Reject HTTP requests
- Use valid SSL/TLS certificates

---

## Common Issues and Troubleshooting

### Issue: 401 "Invalid audience"

**Symptoms:**
```json
{
  "error": "Invalid audience: api://wrong-guid. Expected one of: [...]"
}
```

**Causes:**
1. Web app requesting wrong scope
2. API's CLIENT_ID misconfigured
3. Token meant for different API

**Fix:**
- Verify web app's `SCOPE` matches `api://{API_CLIENT_ID}`
- Check API's `CLIENT_ID` environment variable
- Ensure API app registration matches

### Issue: 401 "Invalid issuer"

**Symptoms:**
```json
{
  "error": "Invalid issuer: https://login.microsoftonline.com/wrong-tenant/v2.0"
}
```

**Causes:**
1. Token from different tenant
2. API's TENANT_ID misconfigured

**Fix:**
- Verify TENANT_ID in API config matches tenant issuing tokens
- Check token's `iss` claim matches expected tenant

### Issue: 401 "Token has expired"

**Symptoms:**
```json
{
  "error": "Token has expired"}
```

**Expected behavior:**
- Access tokens expire after ~1 hour
- Web app should automatically refresh

**Fix:**
- Ensure web app uses `acquire_token_silent()` (auto-refreshes)
- Check web app isn't caching expired tokens
- Verify refresh token still valid

### Issue: 401 "Invalid token"

**Symptoms:**
```json
{
  "error": "Invalid token: ..."}
```

**Causes:**
1. Malformed token (not valid JWT)
2. Signature verification failed
3. Wrong signing algorithm

**Fix:**
- Check token format (should be three base64 parts separated by dots)
- Verify token not corrupted during transmission
- Ensure using RS256 algorithm

### Issue: Can't fetch JWKS

**Symptoms:**
```json
{
  "error": "Token validation failed: ..."}
```

**Causes:**
1. Network connectivity issues
2. Microsoft endpoint down (rare)
3. Firewall blocking HTTPS to Microsoft

**Fix:**
- Check API has internet access
- Verify can reach `login.microsoftonline.com`
- Check firewall rules

---

## Summary

This protected API implements industry-standard JWT validation:

1. **Extracts Bearer token** from Authorization header
2. **Fetches public key** from Microsoft JWKS endpoint
3. **Verifies signature** using cryptographic validation
4. **Checks expiration** ensures token still valid
5. **Validates audience** ensures token for this API
6. **Validates issuer** ensures token from trusted source
7. **Returns claims** if all validation passes

**Key security features:**
- Asymmetric cryptography (RSA-256)
- Automatic public key management
- Multiple validation checks
- Defense against common attacks
- Clear error messages for debugging

**Use cases:**
- Protecting REST APIs
- Validating user identity
- Enforcing API permissions
- Returning token information for debugging

**Best practices demonstrated:**
- Decorator pattern for reusable validation
- Comprehensive error handling
- Support for multiple token formats
- Automatic key rotation handling
- Thread-safe request context
