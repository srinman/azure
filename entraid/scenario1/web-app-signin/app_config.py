"""
Configuration file for Entra ID Web App
Fill in the values after running setup-entraid.sh
"""

import os

# Application (client) ID from app registration
CLIENT_ID = os.getenv("CLIENT_ID", "YOUR_CLIENT_ID_HERE")

# Client secret from app registration
CLIENT_SECRET = os.getenv("CLIENT_SECRET", "YOUR_CLIENT_SECRET_HERE")

# Tenant ID (Directory ID)
TENANT_ID = os.getenv("TENANT_ID", "YOUR_TENANT_ID_HERE")

# Authority URL - for single tenant apps
AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}"

# For multi-tenant apps, use:
# AUTHORITY = "https://login.microsoftonline.com/common"

# Scopes requested during authentication
# For web app sign-in, pass empty list to get OpenID Connect defaults
SCOPE = []

# Redirect path (must match what's registered in Entra ID)
REDIRECT_PATH = "/getAToken"

# Flask session configuration
SESSION_TYPE = "filesystem"  # Store sessions on filesystem
SECRET_KEY = os.getenv("SECRET_KEY", "dev-secret-key-change-in-production")

# For production, set SECRET_KEY to a secure random value:
# python -c "import secrets; print(secrets.token_hex(32))"
