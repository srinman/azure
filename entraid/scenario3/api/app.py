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

# Valid audiences - tokens can have either format
# - Just the client ID (GUID)
# - Application ID URI format: api://{client_id}
VALID_AUDIENCES = [
    CLIENT_ID,
    f"api://{CLIENT_ID}"
]

# Microsoft signing keys endpoint
JWKS_URI = f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys"

# Initialize PyJWKClient for automatic key fetching and caching
jwks_client = PyJWKClient(JWKS_URI)

def validate_token(f):
    """Decorator to validate access token"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        # Get token from Authorization header
        auth_header = request.headers.get('Authorization', '')
        
        if not auth_header.startswith('Bearer '):
            return jsonify({"error": "Missing or invalid Authorization header"}), 401
        
        token = auth_header.split(' ')[1]
        
        try:
            # Get the signing key from the token's header
            # PyJWKClient automatically fetches the key from Microsoft's JWKS endpoint
            # and converts it to the proper PEM format
            signing_key = jwks_client.get_signing_key_from_jwt(token)
            
            # Validate and decode token
            # The signing_key.key is already in the correct PEM format
            # Note: We validate audience and issuer manually to support multiple formats
            payload = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256"],
                options={"verify_aud": False, "verify_iss": False}  # Manual validation below
            )
            
            # Manually validate audience - tokens can have different formats
            # - Just the client ID (GUID): {API_CLIENT_ID}
            # - Application ID URI: api://{API_CLIENT_ID}
            if payload.get("aud") not in VALID_AUDIENCES:
                return jsonify({"error": f"Invalid audience: {payload.get('aud')}. Expected one of: {VALID_AUDIENCES}"}), 401
            
            # Manually validate issuer - Microsoft tokens can have different formats
            # Possible issuers:
            # - https://sts.windows.net/{tenant_id}/
            # - https://login.microsoftonline.com/{tenant_id}/v2.0
            # - https://login.microsoftonline.com/{tenant_id}/
            valid_issuers = [
                f"https://sts.windows.net/{TENANT_ID}/",
                f"https://login.microsoftonline.com/{TENANT_ID}/v2.0",
                f"https://login.microsoftonline.com/{TENANT_ID}/"
            ]
            
            if payload.get("iss") not in valid_issuers:
                return jsonify({"error": f"Invalid issuer: {payload.get('iss')}"}), 401
            
            # Store claims in request context
            request.token_claims = payload
            
        except jwt.ExpiredSignatureError:
            return jsonify({"error": "Token has expired"}), 401
        except jwt.InvalidTokenError as e:
            return jsonify({"error": f"Invalid token: {str(e)}"}), 401
        except Exception as e:
            return jsonify({"error": f"Token validation failed: {str(e)}"}), 401
        
        return f(*args, **kwargs)
    
    return decorated_function


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


@app.route("/api/claims")
@validate_token
def get_claims():
    """
    Protected endpoint - Returns all claims from the access token
    Requires valid Entra ID access token in Authorization header
    """
    claims = request.token_claims
    
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


@app.route("/health")
def health():
    """Health check endpoint"""
    return jsonify({"status": "healthy"}), 200


if __name__ == "__main__":
    port = int(os.getenv("PORT", 5001))
    app.run(host='0.0.0.0', port=port, debug=True)
