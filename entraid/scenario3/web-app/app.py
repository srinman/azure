"""
Web App that Calls Protected API using Managed Identity
Uses User-Assigned Managed Identity with Federated Credentials instead of client secret
"""

import uuid
import requests
from flask import Flask, render_template, session, request, redirect, url_for
from flask_session import Session
import msal
from azure.identity import ManagedIdentityCredential
import app_config

app = Flask(__name__)
app.config.from_object(app_config)
Session(app)  # Initializes Flask-Session with filesystem storage

from werkzeug.middleware.proxy_fix import ProxyFix
app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1, x_host=1)


@app.route("/")
def index():
    """Home page - shows sign-in status"""
    if not session.get("user"):
        return render_template('index.html', user=None, version=msal.__version__)
    
    return render_template('index.html', 
                         user=session["user"], 
                         version=msal.__version__)


@app.route("/login")
def login():
    """Initiate authentication flow"""
    session["state"] = str(uuid.uuid4())
    auth_app = _build_msal_app()
    
    # Request scopes to call the API
    auth_url = auth_app.get_authorization_request_url(
        app_config.SCOPE,
        state=session["state"],
        redirect_uri=url_for("authorized", _external=True)
    )
    
    return redirect(auth_url)


@app.route(app_config.REDIRECT_PATH)
def authorized():
    """Handle the redirect from Entra ID after authentication"""
    if request.args.get('state') != session.get("state"):
        return redirect(url_for("index"))
    
    if "code" in request.args:
        cache = _load_cache()
        auth_app = _build_msal_app(cache=cache)
        
        result = auth_app.acquire_token_by_authorization_code(
            request.args['code'],
            scopes=app_config.SCOPE,
            redirect_uri=url_for("authorized", _external=True)
        )
        
        if "error" in result:
            return render_template("auth_error.html", result=result)
        
        session["user"] = result.get("id_token_claims")
        _save_cache(cache)
    
    return redirect(url_for("index"))


@app.route("/logout")
def logout():
    """Sign out the user"""
    session.clear()
    
    return redirect(
        app_config.AUTHORITY + "/oauth2/v2.0/logout" +
        "?post_logout_redirect_uri=" + url_for("index", _external=True)
    )


@app.route("/call-api")
def call_api():
    """Call the protected API and display claims"""
    token = _get_token_from_cache(app_config.SCOPE)
    
    if not token:
        return redirect(url_for("login"))
    
    # Call the protected API
    api_url = app_config.API_ENDPOINT
    headers = {'Authorization': 'Bearer ' + token['access_token']}
    
    try:
        response = requests.get(api_url, headers=headers)
        
        if response.status_code == 200:
            api_data = response.json()
            return render_template('api_response.html', 
                                 result=api_data,
                                 api_url=api_url)
        else:
            error_data = {
                "error": f"API returned status {response.status_code}",
                "details": response.text
            }
            return render_template('api_error.html', result=error_data)
            
    except Exception as e:
        error_data = {
            "error": "Failed to call API",
            "details": str(e)
        }
        return render_template('api_error.html', result=error_data)


def _load_cache():
    """Load token cache from session"""
    cache = msal.SerializableTokenCache()
    if session.get("token_cache"):
        cache.deserialize(session["token_cache"])
    return cache


def _save_cache(cache):
    """Save token cache to session"""
    if cache.has_state_changed:
        session["token_cache"] = cache.serialize()


def _build_msal_app(cache=None, authority=None):
    """
    Build a ConfidentialClientApplication instance using Managed Identity
    
    Instead of using a client secret, this uses a managed identity credential
    that acquires tokens on behalf of the app registration via federated credentials.
    """
    # Get managed identity credential
    # If MANAGED_IDENTITY_CLIENT_ID is set, use specific managed identity
    # Otherwise, use system-assigned managed identity
    if app_config.MANAGED_IDENTITY_CLIENT_ID:
        credential = ManagedIdentityCredential(
            client_id=app_config.MANAGED_IDENTITY_CLIENT_ID
        )
    else:
        credential = ManagedIdentityCredential()
    
    # Get access token for the app registration using managed identity
    # The managed identity must have federated credentials configured
    # to impersonate the app registration
    def get_token_for_client():
        """
        Acquire token using managed identity for client credential flow
        The managed identity gets a token to act as the app registration
        """
        # For federated credentials, the audience must be api://AzureADTokenExchange
        # This is the standard audience for workload identity federation
        token_result = credential.get_token(
            "api://AzureADTokenExchange"
        )
        return token_result.token
    
    return msal.ConfidentialClientApplication(
        app_config.CLIENT_ID,
        authority=authority or app_config.AUTHORITY,
        client_credential={"client_assertion": get_token_for_client},
        token_cache=cache
    )


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


if __name__ == "__main__":
    port = int(app_config.PORT)
    app.run(host='0.0.0.0', port=port, debug=True)
