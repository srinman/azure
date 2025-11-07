"""
Configuration file for Web App using Managed Identity
"""

import os

# Web App Client ID
CLIENT_ID = os.getenv("CLIENT_ID", "YOUR_CLIENT_ID")

# Managed Identity Client ID (User-Assigned Managed Identity)
# This is the client ID of the managed identity, NOT the app registration
MANAGED_IDENTITY_CLIENT_ID = os.getenv("MANAGED_IDENTITY_CLIENT_ID", None)

TENANT_ID = os.getenv("TENANT_ID", "YOUR_TENANT_ID")

# API Client ID (the protected API's application ID)
API_CLIENT_ID = os.getenv("API_CLIENT_ID", "YOUR_API_CLIENT_ID")

# Authority
AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}"

# Scopes - requesting access to the API
# Format: api://{API_CLIENT_ID}/scope_name
SCOPE = [f"api://{API_CLIENT_ID}/access_as_user"]

# Redirect path
REDIRECT_PATH = "/getAToken"

# API endpoint URL
API_ENDPOINT = os.getenv("API_ENDPOINT", "http://localhost:5001/api/claims")

# Flask session configuration
SESSION_TYPE = "filesystem"
SECRET_KEY = os.getenv("SECRET_KEY", "dev-secret-key-change-in-production")

# Port
PORT = os.getenv("PORT", "5000")
