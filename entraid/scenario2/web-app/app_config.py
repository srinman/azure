"""
Configuration file for Web App
"""

import os

# Web App Client ID
CLIENT_ID = os.getenv("CLIENT_ID", "YOUR_CLIENT_ID")
CLIENT_SECRET = os.getenv("CLIENT_SECRET", "YOUR_CLIENT_SECRET")
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
