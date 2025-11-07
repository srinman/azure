#!/bin/bash

# Cleanup Script - Removes Entra ID App Registration
# This deletes the app created by setup-entraid.sh

set -e

echo "========================================"
echo "Entra ID App Cleanup"
echo "========================================"
echo ""

# Find all apps with our naming pattern
echo "Finding webapp-signin-demo app registrations..."
APPS=$(az ad app list --filter "startswith(displayName,'webapp-signin-demo')" --query "[].{Name:displayName, AppId:appId}" -o tsv)

if [ -z "$APPS" ]; then
    echo "No webapp-signin-demo apps found."
    exit 0
fi

echo "Found the following apps:"
echo "$APPS"
echo ""

# Parse and delete each app
echo "$APPS" | while read -r NAME APP_ID; do
    echo "Deleting: $NAME (App ID: $APP_ID)"
    az ad app delete --id "$APP_ID"
    echo "✓ Deleted successfully"
    echo ""
done

echo "========================================"
echo "Cleanup Complete!"
echo "========================================"
echo ""
echo "All webapp-signin-demo app registrations have been removed."
echo "Environment variables in your current session are still set."
echo "To clear them, run: unset CLIENT_ID CLIENT_SECRET TENANT_ID"
echo ""
