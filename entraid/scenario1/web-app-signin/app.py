"""
Flask Web Application with Entra ID Sign-In
Implements the "Web app that signs in a user" scenario using MSAL Python
"""

import uuid
from flask import Flask, render_template, session, request, redirect, url_for
from flask_session import Session
import msal
import app_config

app = Flask(__name__)
app.config.from_object(app_config)
Session(app)  # Initializes Flask-Session with filesystem storage (see app_config.py SESSION_TYPE)

# This section is needed for url_for("foo", _external=True) to automatically
# generate http scheme when this sample is running on localhost,
# and to generate https scheme when it is deployed behind reversed proxy.
from werkzeug.middleware.proxy_fix import ProxyFix
app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1, x_host=1)


@app.route("/")
def index():
    """Home page - shows sign-in status
    
    Session Persistence Behavior:
    - On first visit: session.get("user") returns None, shows sign-in button
    - After login: MSAL stores user info in session["user"]
    - Session saved to flask_session/ directory (filesystem storage)
    - Browser receives session cookie
    - On app restart: Flask loads session from disk using cookie
    - User appears logged in automatically until:
      * They click "Sign Out" (clears session)
      * Session expires
      * flask_session/ directory is deleted
      * Browser cookies are cleared
    """
    if not session.get("user"):
        return render_template('index.html', user=None, version=msal.__version__)
    
    return render_template('index.html', 
                         user=session["user"], 
                         version=msal.__version__)


@app.route("/login")
def login():
    """Initiate authentication flow"""
    # Generate a unique state parameter to prevent CSRF attacks
    session["state"] = str(uuid.uuid4())
    
    # Create an MSAL ConfidentialClientApplication instance
    auth_app = _build_msal_app()
    
    # Get authorization request URL
    # This will redirect user to Entra ID login page
    auth_url = auth_app.get_authorization_request_url(
        app_config.SCOPE,  # Scopes requested
        state=session["state"],
        redirect_uri=url_for("authorized", _external=True)
    )
    
    return redirect(auth_url)


@app.route(app_config.REDIRECT_PATH)  # Default: /getAToken
def authorized():
    """Handle the redirect from Entra ID after authentication"""
    # Verify state parameter to prevent CSRF
    if request.args.get('state') != session.get("state"):
        return redirect(url_for("index"))
    
    # Check if we received an authorization code
    if "code" in request.args:
        cache = _load_cache()
        auth_app = _build_msal_app(cache=cache)
        
        # Exchange authorization code for tokens
        result = auth_app.acquire_token_by_authorization_code(
            request.args['code'],
            scopes=app_config.SCOPE,
            redirect_uri=url_for("authorized", _external=True)
        )
        
        if "error" in result:
            return render_template("auth_error.html", result=result)
        
        # Store user information in session
        session["user"] = result.get("id_token_claims")
        _save_cache(cache)
    
    return redirect(url_for("index"))


@app.route("/logout")
def logout():
    """Sign out the user
    
    Clears both:
    1. Flask session (stored in flask_session/ directory)
    2. Entra ID session (by redirecting to Microsoft logout endpoint)
    
    After logout, user must sign in again on next visit.
    """
    session.clear()  # Clear Flask session
    
    # Redirect to Entra ID logout endpoint
    # This ensures the user is logged out from Entra ID as well
    return redirect(
        app_config.AUTHORITY + "/oauth2/v2.0/logout" +
        "?post_logout_redirect_uri=" + url_for("index", _external=True)
    )





def _load_cache():
    """Load token cache from session
    
    Session is stored on filesystem (flask_session/ directory) and survives app restarts.
    This is why users stay logged in even after restarting the Flask app.
    """
    cache = msal.SerializableTokenCache()
    if session.get("token_cache"):
        cache.deserialize(session["token_cache"])
    return cache


def _save_cache(cache):
    """Save token cache to session"""
    if cache.has_state_changed:
        session["token_cache"] = cache.serialize()


def _build_msal_app(cache=None, authority=None):
    """Build a ConfidentialClientApplication instance"""
    return msal.ConfidentialClientApplication(
        app_config.CLIENT_ID,
        authority=authority or app_config.AUTHORITY,
        client_credential=app_config.CLIENT_SECRET,
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
    app.run(host='0.0.0.0', port=5000, debug=True)
