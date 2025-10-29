# Simplified Authentication with .default Scope

## Overview

This guide explains how to use `.default` scope for Azure managed identity authentication, which **eliminates the need for app roles** while maintaining strong security.

## Why Use .default Scope?

### ❌ Traditional App Roles Approach (Complex)

```bash
# Step 1: Create App Registration
az ad app create --display-name "my-api"

# Step 2: Define app roles in JSON
cat > app-roles.json << EOF
[{
  "allowedMemberTypes": ["Application"],
  "displayName": "Function.Invoke",
  "id": "unique-guid-here",
  "value": "Function.Invoke"
}]
EOF

# Step 3: Update App Registration with roles
az ad app update --id $APP_ID --app-roles @app-roles.json

# Step 4: Get Service Principal ID
SP_ID=$(az ad sp show --id $APP_ID --query id -o tsv)

# Step 5: Assign role to managed identity (Microsoft Graph API)
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${IDENTITY_PRINCIPAL_ID}/appRoleAssignments" \
  --body "{...complex JSON payload...}"

# Step 6: (Optional) Enable role requirement
az ad sp update --id $SP_ID --set appRoleAssignmentRequired=true

# Step 7: Request token
curl -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?resource=api://${APP_ID}"

# Step 8: Validate roles claim in your code
if "Function.Invoke" not in token['roles']:
    return 403
```

### ✅ Simplified .default Scope (Simple)

```bash
# Step 1: Create App Registration
az ad app create --display-name "my-api"

# Step 2: Set Application ID URI
az ad app update --id $APP_ID --identifier-uris "api://${APP_ID}"

# Step 3: Request token with .default scope
curl -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?resource=${APP_ID}/.default"

# Step 4: Validate client_id in your code (no roles needed!)
if token['appid'] != ALLOWED_CLIENT_ID:
    return 403
```

**Result**: 5 fewer steps, no Graph API calls, no role management complexity!

---

## How .default Scope Works

### Token Request

```bash
# Format: {APP_ID}/.default or api://{APP_ID}/.default
RESOURCE="12345678-1234-1234-1234-123456789abc/.default"

TOKEN_RESPONSE=$(curl -s -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=${RESOURCE}")

ACCESS_TOKEN=$(echo $TOKEN_RESPONSE | jq -r '.access_token')
```

### Token Claims

**With .default scope, the token contains:**

```json
{
  "aud": "12345678-1234-1234-1234-123456789abc",
  "iss": "https://sts.windows.net/{tenant-id}/",
  "iat": 1730000000,
  "exp": 1730003600,
  "appid": "vm-managed-identity-client-id",
  "oid": "vm-managed-identity-principal-id",
  "sub": "vm-managed-identity-principal-id",
  "tid": "{tenant-id}"
}
```

**Note**: No `roles` claim! That's perfectly fine - you validate `appid` instead.

---

## Security Comparison

### App Roles Approach

```
┌─────────────────────────────────────────┐
│ VM Managed Identity                     │
│ Client ID: abc-123                      │
└────────────┬────────────────────────────┘
             │
             │ 1. Request token for api://xyz-789
             ▼
┌─────────────────────────────────────────┐
│ Entra ID                                │
│ - Check: Does VM have app role assigned?│
│ - If appRoleAssignmentRequired=true:    │
│   - YES → Issue token with roles claim  │
│   - NO → Deny (AADSTS501051)           │
│ - If appRoleAssignmentRequired=false:   │
│   - Issue token (may have roles claim)  │
└────────────┬────────────────────────────┘
             │
             │ 2. Token with roles: ["Function.Invoke"]
             ▼
┌─────────────────────────────────────────┐
│ Function App                            │
│ - Validate JWT signature                │
│ - Check audience                        │
│ - Check roles claim (backup)            │
│ - Check client_id (primary)             │
└─────────────────────────────────────────┘

Security Layers:
🔒 Layer 1: Entra ID role check (if enabled)
🔒 Layer 2: JWT signature validation
🔒 Layer 3: Roles claim validation
🔒 Layer 4: Client ID validation
```

### .default Scope Approach

```
┌─────────────────────────────────────────┐
│ VM Managed Identity                     │
│ Client ID: abc-123                      │
└────────────┬────────────────────────────┘
             │
             │ 1. Request token for xyz-789/.default
             ▼
┌─────────────────────────────────────────┐
│ Entra ID                                │
│ - No role checks needed                 │
│ - Issue token with audience=APP_ID      │
└────────────┬────────────────────────────┘
             │
             │ 2. Token with appid: "abc-123"
             ▼
┌─────────────────────────────────────────┐
│ Function App                            │
│ - Validate JWT signature                │
│ - Check audience                        │
│ - Check client_id (primary)             │
└─────────────────────────────────────────┘

Security Layers:
🔒 Layer 1: JWT signature validation
🔒 Layer 2: Client ID validation

Still secure! Authorization happens in your code.
```

---

## Implementation Steps

### 1. Update Token Request (VM Side)

**Before (with app roles):**
```bash
RESOURCE="api://${APP_ID}"
curl -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?resource=${RESOURCE}"
```

**After (with .default):**
```bash
RESOURCE="${APP_ID}/.default"
curl -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?resource=${RESOURCE}"
```

### 2. Update Audience Validation (Function App Side)

**Before (strict audience check):**
```python
def validate_jwt_token(token, tenant_id, expected_audience):
    decoded_token = jwt.decode(
        token,
        signing_key,
        algorithms=['RS256'],
        audience=expected_audience,  # Must be exactly "api://APP_ID"
        issuer=f'https://sts.windows.net/{tenant_id}/'
    )
    return decoded_token, None
```

**After (flexible audience check):**
```python
def validate_jwt_token(token, tenant_id, expected_audience):
    # Accept both "api://APP_ID" and "APP_ID" as valid audiences
    decoded_token = jwt.decode(
        token,
        signing_key,
        algorithms=['RS256'],
        audience=expected_audience,  # Can be "api://APP_ID" or just "APP_ID"
        issuer=f'https://sts.windows.net/{tenant_id}/'
    )
    return decoded_token, None

# In your HTTP trigger:
expected_audiences = [f'api://{app_id}', app_id]
for expected_audience in expected_audiences:
    decoded_token, error = validate_jwt_token(token, tenant_id, expected_audience)
    if decoded_token:
        break
```

### 3. Validation Logic

**Both approaches use the same client ID validation:**

```python
# Extract caller's client ID from token
caller_appid = decoded_token.get('appid')
caller_azp = decoded_token.get('azp')
caller_client_id = caller_appid or caller_azp

# Validate against allowed client ID
allowed_client_id = os.environ.get('ALLOWED_CLIENT_ID')
if caller_client_id != allowed_client_id:
    return func.HttpResponse(
        json.dumps({"error": "Forbidden"}),
        status_code=403
    )
```

---

## What You Skip with .default

### ❌ Don't Need: Define App Roles

```bash
# Skip this entire section!
cat > app-roles.json << EOF
[{
  "allowedMemberTypes": ["Application"],
  "displayName": "Function.Invoke",
  "id": "746c20c8-ac75-44dd-8864-6afab4399c65",
  "value": "Function.Invoke"
}]
EOF

az ad app update --id $APP_ID --app-roles @app-roles.json
```

### ❌ Don't Need: Assign Roles via Graph API

```bash
# Skip this entire section!
SP_ID=$(az ad sp show --id $APP_ID --query id -o tsv)

az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${IDENTITY_PRINCIPAL_ID}/appRoleAssignments" \
  --body "{
    \"principalId\": \"${IDENTITY_PRINCIPAL_ID}\",
    \"resourceId\": \"${SP_ID}\",
    \"appRoleId\": \"746c20c8-ac75-44dd-8864-6afab4399c65\"
  }"
```

### ❌ Don't Need: Enable Role Assignment Requirement

```bash
# Skip this entire section!
az ad sp update --id $SP_ID --set appRoleAssignmentRequired=true
```

### ❌ Don't Need: Validate Roles Claim

```python
# Skip this validation!
roles = decoded_token.get('roles', [])
if 'Function.Invoke' not in roles:
    return func.HttpResponse("Missing required role", status_code=403)
```

---

## When to Use Each Approach

### Use .default Scope When:

✅ You want simple, fast setup  
✅ You're managing a small number of identities  
✅ Client ID validation is sufficient for your security needs  
✅ You don't need Entra ID to enforce authorization  
✅ You want easier troubleshooting (fewer moving parts)  

### Use App Roles When:

✅ You need compliance/audit trail at Entra ID level  
✅ You want defense-in-depth (Entra ID + app validation)  
✅ You're managing many different caller identities  
✅ You need fine-grained permissions (multiple different roles)  
✅ You want Entra ID to prevent token issuance to unauthorized callers  

---

## Migration Path

If you have existing app roles but want to simplify:

1. **Test with .default scope first** (doesn't break existing setup)
2. **Update Function App** to accept both audience formats
3. **Update VM scripts** to use `.default` scope
4. **Verify everything works**
5. **(Optional) Clean up**: Remove app role definitions and assignments

You can run both approaches in parallel during migration!

---

## Common Questions

### Q: Is .default scope less secure?

**A:** No! Security comes from:
- ✅ JWT signature validation (same in both)
- ✅ Audience validation (same in both)
- ✅ Client ID validation (same in both)

App roles add an *extra* layer at Entra ID, but the fundamental security is the same.

### Q: Can any managed identity get tokens with .default?

**A:** Yes, but your Function App validates the client ID and rejects unauthorized callers. This is **application-level authorization** instead of **Entra ID-level authorization**.

### Q: What about the roles claim?

**A:** With `.default` scope, the token won't have a `roles` claim. That's expected! You don't need it when validating `appid` or `azp` claims.

### Q: Can I use .default with system-assigned managed identities?

**A:** Yes! The `.default` scope works with both user-assigned and system-assigned managed identities.

---

## Example: Complete Request Flow

```bash
# 1. VM requests token with .default scope
curl -s -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=12345678-1234-1234-1234-123456789abc/.default"

# 2. Entra ID responds with token
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGci...",
  "expires_in": "3599",
  "resource": "12345678-1234-1234-1234-123456789abc",
  "token_type": "Bearer"
}

# 3. VM calls Function App with token
curl -H "Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGci..." \
  "https://func-app.azurewebsites.net/api/HttpTrigger"

# 4. Function App validates token
# - Verifies JWT signature ✅
# - Checks audience = APP_ID ✅
# - Checks appid = ALLOWED_CLIENT_ID ✅
# - Returns 200 OK

# 5. Success response
{
  "message": "Successfully authenticated!",
  "authenticated": true,
  "caller_info": {
    "client_id": "vm-client-id"
  }
}
```

---

## Summary

The `.default` scope approach provides:

- ✅ **Simpler setup** - 5 fewer configuration steps
- ✅ **Easier troubleshooting** - Fewer components to debug
- ✅ **Same security** - JWT + client ID validation
- ✅ **Faster deployment** - No Graph API calls needed
- ✅ **Easier maintenance** - No role assignments to manage

**Bottom line**: Unless you specifically need defense-in-depth with Entra ID enforcing authorization, use `.default` scope for simpler and faster setup!
