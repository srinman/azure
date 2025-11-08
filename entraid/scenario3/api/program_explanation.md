# Step-by-Step Program Explanation: Protected API (Scenario 3)

This document provides a detailed line-by-line explanation of the protected API used in Scenario 3.

---

## Overview

The API in Scenario 3 is **100% IDENTICAL** to the API in Scenario 2.

**Why?**

Because the API **doesn't care** how the web app authenticated itself to get the access token. The API only cares about:

1. Is the access token valid?
2. Was it issued by our Entra ID tenant?
3. Is the audience correct (token meant for this API)?
4. Is it not expired?

**From the API's perspective:**

- Scenario 2: Web app used client secret to get access token
- Scenario 3: Web app used managed identity to get access token

**Result:** Same access token format, same validation process, same API code.

---

## API Code

The API code is **byte-for-byte identical** to Scenario 2:

```python
"""
Protected API - Returns token claims
This API validates Entra ID access tokens and returns the claims
"""

from flask import Flask, jsonify, request
from functools import wraps
import jwt
from jwt import PyJWKClient
import os

app = Flask(__name__)

# Configuration from environment variables
TENANT_ID = os.getenv("TENANT_ID", "YOUR_TENANT_ID")
CLIENT_ID = os.getenv("API_CLIENT_ID", "YOUR_API_CLIENT_ID")

VALID_AUDIENCES = [
    CLIENT_ID,
    f"api://{CLIENT_ID}"
]

JWKS_URI = f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys"
jwks_client = PyJWKClient(JWKS_URI)

# ... exact same validation code ...
# ... exact same endpoints ...
```

---

## Why APIs Don't Need to Change

### Access Token Properties

Access tokens contain **how the token was obtained** in their claims:

**Scenario 2 Token (Client Secret):**
```json
{
  "aud": "api://api-client-id",
  "iss": "https://login.microsoftonline.com/tenant/v2.0",
  "appid": "webapp-client-id",
  "azp": "webapp-client-id",
  "scp": "access_as_user",
  "name": "John Doe",
  ...
}
```

**Scenario 3 Token (Managed Identity):**
```json
{
  "aud": "api://api-client-id",
  "iss": "https://login.microsoftonline.com/tenant/v2.0",
  "appid": "webapp-client-id",
  "azp": "webapp-client-id",
  "scp": "access_as_user",
  "name": "John Doe",
  ...
}
```

**They're the SAME!**

The access token represents:
- **Who the user is** (name, oid, etc.)
- **What app is calling** (appid)
- **What permissions granted** (scp)
- **What resource it's for** (aud)

It does **NOT** contain:
- Whether client secret or managed identity was used
- How the app authenticated
- Internal authentication details

### Separation of Concerns

**Web App's Responsibility:**
- Authenticate itself to Entra ID (secret or MI)
- Authenticate users
- Acquire access tokens
- Call APIs

**API's Responsibility:**
- Validate access tokens
- Verify signature, audience, issuer
- Check permissions (scopes)
- Return data

**Entra ID's Responsibility:**
- Issue tokens
- Verify app identity (accepts secret OR MI assertion)
- Manage user authentication
- Sign tokens cryptographically

The API doesn't know or care about the app's authentication method - it only validates the resulting token.

---

## Token Validation Flow (Same for Both Scenarios)

1. **Web app calls API:**
   ```
   GET /api/claims
   Authorization: Bearer eyJ0eXAiOiJKV1Q...
   ```

2. **API extracts token from header**

3. **API validates token:**
   - Fetches public key from Microsoft JWKS
   - Verifies cryptographic signature
   - Checks expiration
   - Validates audience matches API's CLIENT_ID
   - Validates issuer from correct tenant

4. **If valid: API returns claims**

5. **If invalid: API returns 401 error**

**No difference** whether token came from Scenario 2 or Scenario 3 app!

---

## What Changes in the Overall System

### Scenario 2 Architecture

```
User Browser
    ↓
Web App (uses CLIENT_SECRET)
    ↓
Microsoft Entra ID
    ↓
Access Token
    ↓
Protected API (validates token)
```

### Scenario 3 Architecture

```
User Browser
    ↓
Web App (uses Managed Identity)
    ↓
Azure Metadata Service (issues MI token)
    ↓
Microsoft Entra ID (accepts MI token via federation)
    ↓
Access Token
    ↓
Protected API (validates token) ← SAME API!
```

**The API is the same box** - it just receives tokens from a web app that authenticated differently.

---

## When API Code WOULD Need to Change

APIs only need different code if:

1. **Different token format**
   - Example: Accepting both Entra ID and another identity provider
   - Different signature algorithms
   - Different claim structures

2. **Additional validation requirements**
   - Example: Check if app used managed identity (requires inspecting token claims)
   - Enforce specific authentication methods
   - Additional custom claims validation

3. **Different authorization logic**
   - Example: Managed identity apps get admin access, secret apps get user access
   - Would check token claims to determine authentication method

**For Scenario 2 vs 3:**
- Same Entra ID issuer ✓
- Same token format ✓
- Same signature algorithm ✓
- Same claims structure ✓
- Same authorization model ✓

**Therefore: Same API code! ✓**

---

## Documentation Reference

For complete line-by-line explanation of how the API works, see:

**[Scenario 2 API Documentation](../scenario2/api/program_explanation.md)**

The documentation is 100% applicable to Scenario 3 API because the code is identical.

---

## Key Takeaways

1. **APIs validate tokens, not authentication methods**
   - Don't care if app used secret, certificate, or managed identity
   - Only care about resulting access token

2. **Access tokens are standardized**
   - Same format regardless of how acquired
   - Contain user identity and permissions
   - Don't reveal app's authentication method

3. **Managed Identity is transparent to downstream services**
   - APIs, other services, Microsoft Graph all see same tokens
   - Zero impact on API code
   - Pure security improvement for the web app

4. **Separation of concerns enables flexibility**
   - Can switch from secret to managed identity
   - No API changes required
   - Backwards compatible

5. **Scenario 3's advantage is in the web app, not the API**
   - Web app more secure (no secrets)
   - API unchanged
   - Users see no difference
   - Backend architecture improved

---

## Summary

**Scenario 3 API is identical to Scenario 2 API.**

The difference between scenarios is **how the web app authenticates**, not how the API validates tokens.

**Web App Authentication:**
- Scenario 2: Client Secret (static password)
- Scenario 3: Managed Identity (dynamic, Azure-issued token)

**API Token Validation:**
- Both scenarios: Same JWT validation process

**For detailed API explanation, refer to Scenario 2 API documentation - it applies equally to Scenario 3.**
