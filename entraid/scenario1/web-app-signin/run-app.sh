#!/bin/bash

# One-command run script - uses existing environment variables or creates new app

if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ] || [ -z "$TENANT_ID" ]; then
    echo "========================================="
    echo "Environment variables not set"
    echo "========================================="
    echo ""
    echo "Running setup to create/configure app..."
    echo ""
    source ./setup-entraid.sh
    echo ""
fi

echo "========================================="
echo "Starting Flask App with Entra ID Sign-In"
echo "========================================="
echo ""
echo "Credentials configured:"
echo "  CLIENT_ID: $CLIENT_ID"
echo "  TENANT_ID: $TENANT_ID"
echo ""
echo "Open your browser to: http://localhost:5000"
echo ""

python3 app.py
