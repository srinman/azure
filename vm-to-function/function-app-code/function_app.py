import azure.functions as func
import logging
import json
import os
import jwt
import requests
from datetime import datetime
from functools import lru_cache

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

@lru_cache(maxsize=1)
def get_jwks_keys(tenant_id):
    """
    Fetch and cache the public keys from Azure AD for JWT verification.
    These keys are used to verify the signature of tokens.
    """
    jwks_url = f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys"
    try:
        response = requests.get(jwks_url, timeout=10)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        logging.error(f"Failed to fetch JWKS keys: {e}")
        return None

def validate_jwt_token(token, tenant_id, expected_audience):
    """
    Validate JWT token:
    1. Verify signature using Azure AD's public keys
    2. Verify expiration
    3. Verify audience
    4. Verify issuer
    """
    try:
        # Decode header to get the key ID
        unverified_header = jwt.get_unverified_header(token)
        kid = unverified_header.get('kid')
        
        if not kid:
            return None, "Token missing 'kid' in header"
        
        # Get Azure AD's public keys
        jwks = get_jwks_keys(tenant_id)
        if not jwks:
            return None, "Failed to retrieve public keys from Azure AD"
        
        # Find the matching key
        signing_key = None
        for key in jwks.get('keys', []):
            if key.get('kid') == kid:
                signing_key = jwt.algorithms.RSAAlgorithm.from_jwk(json.dumps(key))
                break
        
        if not signing_key:
            return None, f"Signing key with kid '{kid}' not found"
        
        # Verify and decode the token
        decoded_token = jwt.decode(
            token,
            signing_key,
            algorithms=['RS256'],
            audience=expected_audience,
            issuer=f'https://sts.windows.net/{tenant_id}/',
            options={
                'verify_signature': True,
                'verify_exp': True,
                'verify_aud': True,
                'verify_iss': True
            }
        )
        
        return decoded_token, None
        
    except jwt.ExpiredSignatureError:
        return None, "Token has expired"
    except jwt.InvalidAudienceError:
        return None, f"Invalid audience. Expected: {expected_audience}"
    except jwt.InvalidIssuerError:
        return None, f"Invalid issuer. Expected: https://sts.windows.net/{tenant_id}/"
    except jwt.InvalidSignatureError:
        return None, "Invalid token signature"
    except Exception as e:
        return None, f"Token validation error: {str(e)}"

@app.route(route="HttpTrigger", methods=["GET", "POST"])
def HttpTrigger(req: func.HttpRequest) -> func.HttpResponse:
    """
    HTTP trigger function that validates caller identity using manual JWT validation.
    Only accepts requests from the specific VM managed identity.
    
    NO Easy Auth required - all validation done in code.
    """
    logging.info('Python HTTP trigger function processed a request.')
    
    # Get configuration from environment
    allowed_client_id = os.environ.get('ALLOWED_CLIENT_ID', '')  # VM managed identity
    test_client_id = os.environ.get('TEST_CLIENT_ID', '')  # For testing from laptop
    tenant_id = os.environ.get('TENANT_ID', '')
    app_id = os.environ.get('APP_ID', '')
    
    if not tenant_id or not app_id:
        logging.error('Missing TENANT_ID or APP_ID configuration')
        return func.HttpResponse(
            json.dumps({
                "error": "Configuration error",
                "message": "Function app not properly configured"
            }),
            status_code=500,
            mimetype="application/json"
        )
    
    # Extract Bearer token from Authorization header
    auth_header = req.headers.get('Authorization', '')
    if not auth_header.startswith('Bearer '):
        logging.warning('No Bearer token provided')
        return func.HttpResponse(
            json.dumps({
                "error": "Authentication required",
                "message": "Request must include Bearer token in Authorization header"
            }),
            status_code=401,
            mimetype="application/json"
        )
    
    token = auth_header[7:]  # Remove 'Bearer ' prefix
    
    # Validate the JWT token
    # When using .default scope, audience might be the APP_ID directly or api://APP_ID
    # We need to accept both formats, and also with /.default suffix
    expected_audiences = [
        f'api://{app_id}',
        app_id,
        f'{app_id}/.default'
    ]
    
    decoded_token = None
    validation_error = None
    
    # Try validating with each possible audience format
    for expected_audience in expected_audiences:
        decoded_token, error = validate_jwt_token(token, tenant_id, expected_audience)
        if decoded_token:
            logging.info(f'Token validated with audience: {expected_audience}')
            break
        validation_error = error
    
    if not decoded_token:
        logging.warning(f'Token validation failed: {validation_error}')
        
        # Try to extract audience from token without validation for debugging
        received_audience = None
        try:
            unverified_payload = jwt.decode(token, options={"verify_signature": False})
            received_audience = unverified_payload.get('aud')
        except:
            received_audience = "Unable to decode token"
        
        return func.HttpResponse(
            json.dumps({
                "error": "Invalid token",
                "message": validation_error,
                "received_audience": received_audience,
                "expected_audiences": expected_audiences,
                "hint": "Token audience must match APP_ID or api://APP_ID"
            }),
            status_code=401,
            mimetype="application/json"
        )
    
    # Extract identity claims from the validated token
    # For managed identities: 'oid' contains the principal ID, 'azp' or 'appid' may contain client ID
    caller_oid = decoded_token.get('oid')
    caller_sub = decoded_token.get('sub')
    caller_appid = decoded_token.get('appid')  # For service principals
    caller_azp = decoded_token.get('azp')      # Authorized party (managed identities)
    
    # Determine the caller's client ID
    # Priority: appid (service principal) > azp (managed identity) > oid (fallback)
    caller_client_id = caller_appid or caller_azp or caller_oid
    
    logging.info(f'Authenticated identity: appid={caller_appid}, azp={caller_azp}, oid={caller_oid}')
    
    # Build list of allowed client IDs
    allowed_ids = []
    if allowed_client_id:
        allowed_ids.append(allowed_client_id.strip())
    if test_client_id:
        allowed_ids.append(test_client_id.strip())
    
    # Validate against allowed client IDs
    if allowed_ids and caller_client_id not in allowed_ids:
        logging.warning(f'Unauthorized caller: {caller_client_id}, expected one of: {allowed_ids}')
        return func.HttpResponse(
            json.dumps({
                "error": "Forbidden",
                "message": f"Client ID {caller_client_id} is not authorized to call this function",
                "debug_info": {
                    "caller_client_id": caller_client_id,
                    "allowed_client_ids": allowed_ids,
                    "token_claims": {
                        "appid": caller_appid,
                        "azp": caller_azp,
                        "oid": caller_oid,
                        "sub": caller_sub
                    }
                }
            }),
            status_code=403,
            mimetype="application/json"
        )
    
    logging.info(f'Authorized request from: {caller_client_id}')
    
    # Determine caller type
    caller_type = "unknown"
    if caller_client_id == allowed_client_id:
        caller_type = "VM managed identity"
    elif caller_client_id == test_client_id:
        caller_type = "Test service principal"
    elif caller_appid:
        caller_type = "Service principal"
    elif caller_oid:
        caller_type = "User"
    
    # Prepare success response
    response_data = {
        "message": "Successfully authenticated!",
        "authenticated": True,
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "caller_info": {
            "client_id": caller_client_id,
            "caller_type": caller_type,
            "object_id": caller_oid,
            "subject": caller_sub,
            "appid_claim": caller_appid,
            "azp_claim": caller_azp
        },
        "token_info": {
            "audience": decoded_token.get('aud'),
            "issuer": decoded_token.get('iss'),
            "issued_at": datetime.fromtimestamp(decoded_token.get('iat', 0)).isoformat() if decoded_token.get('iat') else None,
            "expires_at": datetime.fromtimestamp(decoded_token.get('exp', 0)).isoformat() if decoded_token.get('exp') else None
        },
        "validation": {
            "allowed_vm_client_id": allowed_client_id,
            "allowed_test_client_id": test_client_id,
            "all_allowed_ids": allowed_ids,
            "client_id_match": caller_client_id in allowed_ids if allowed_ids else True,
            "claim_used": "appid" if caller_appid else ("azp" if caller_azp else "oid"),
            "method": "code-based-jwt-validation"
        }
    }
    
    return func.HttpResponse(
        json.dumps(response_data, indent=2),
        status_code=200,
        mimetype="application/json"
    )