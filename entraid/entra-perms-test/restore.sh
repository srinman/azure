#!/usr/bin/env bash
# =============================================================================
# RESTORE SCRIPT — Entra ID App Permissions
# =============================================================================
#
# USE CASE:  Run this script to fully overwrite the current permissions on
#            your Enterprise App back to the baseline state hardcoded below.
#            Backup files created by backup.sh are stored in ~/bkp/ —
#            check there if you need to review what was captured before restoring.
#
# WHAT THIS SCRIPT DOES:
#   1. Overwrites requiredResourceAccess on the App Registration
#   2. Deletes all current oauth2PermissionGrants (delegated consent grants)
#      and recreates from backup
#   3. Deletes all current appRoleAssignments (application permissions)
#      and recreates from backup
#
# PRE-REQUISITES:
#   - az CLI installed and logged in (az login)
#   - Logged-in account must have Application Administrator or
#     Global Administrator role in the tenant
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURE THESE VALUES FOR YOUR APP
# APP_ID = Application (client) ID from App Registrations blade
# SP_ID  = Object ID from Enterprise Applications blade (same as SP Object ID)
# ---------------------------------------------------------------------------
APP_ID="<YOUR_APP_ID>"
# SP_ID = the "Object ID" shown in Entra portal → Enterprise Applications → Overview.
# The portal labels it "Object ID" (every Entra object has an id), but it IS the
# Service Principal ID. It is different from the App Registration's own Object ID.
SP_ID="<YOUR_SP_ID>"

echo "========================================"
echo "Restoring permissions for: <your-client-app>"
echo "App ID: $APP_ID"
echo "SP ID:  $SP_ID"
echo "========================================"
echo ""

# --- STEP 1: Restore requiredResourceAccess on the App Registration ----------
# This sets the permissions listed in the "API permissions" blade of the
# App Registration. It does NOT grant admin consent — that is handled in
# steps 2 and 3.
echo "[1/3] Restoring requiredResourceAccess on App Registration..."

az ad app update --id "$APP_ID" \
  --required-resource-accesses '[
    {
      "resourceAppId": "<YOUR_API_APP_ID>",
      "resourceAccess": [
        { "id": "<YOUR_APP_ROLE_ID>", "type": "Role" }
      ]
    },
    {
      "resourceAppId": "00000003-0000-0000-c000-000000000000",
      "resourceAccess": [
        { "id": "<USER_READ_SCOPE_ID>", "type": "Scope" }
      ]
    }
  ]'

echo "  Done."
echo ""

# --- STEP 2: Restore oauth2PermissionGrants (Delegated consent grants) -------
# These represent admin-consented delegated permissions granted to the SP.
# Strategy: delete all existing grants for this SP, then recreate from backup.
echo "[2/3] Restoring oauth2PermissionGrants (delegated permissions)..."

echo "  Fetching current grants..."
CURRENT_GRANT_IDS=$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/oauth2PermissionGrants" \
  --query "value[].id" -o tsv 2>/dev/null || true)

if [[ -n "$CURRENT_GRANT_IDS" ]]; then
  while IFS= read -r grant_id; do
    [[ -z "$grant_id" ]] && continue
    echo "  Deleting grant: $grant_id"
    az rest --method DELETE \
      --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$grant_id"
  done <<< "$CURRENT_GRANT_IDS"
else
  echo "  No existing grants to remove."
fi

echo "  Recreating backup grant: Microsoft Graph / User.Read (AllPrincipals)..."
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" \
  --body "{
    \"clientId\":    \"$SP_ID\",
    \"consentType\": \"AllPrincipals\",
    \"resourceId\":  \"<GRAPH_SP_ID>\",
    \"scope\":       \"User.Read\"
  }"

echo "  Done."
echo ""

# --- STEP 3: Restore appRoleAssignments (Application permissions) ------------
# These represent admin-consented application permissions (app roles) granted
# to the SP by other resource APIs.
# Strategy: delete all existing assignments for this SP, then recreate from backup.
echo "[3/3] Restoring appRoleAssignments (application permissions)..."

echo "  Fetching current app role assignments..."
CURRENT_ASSIGNMENT_IDS=$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignments" \
  --query "value[].id" -o tsv 2>/dev/null || true)

if [[ -n "$CURRENT_ASSIGNMENT_IDS" ]]; then
  while IFS= read -r assignment_id; do
    [[ -z "$assignment_id" ]] && continue
    echo "  Deleting app role assignment: $assignment_id"
    az rest --method DELETE \
      --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignments/$assignment_id"
  done <<< "$CURRENT_ASSIGNMENT_IDS"
else
  echo "  No existing app role assignments to remove."
fi

echo "  Recreating backup assignment: <your-api-app> / <YourAppRole>..."
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignments" \
  --body "{
    \"principalId\": \"$SP_ID\",
    \"resourceId\":  \"<YOUR_API_APP_SP_ID>\",
    \"appRoleId\":   \"<YOUR_APP_ROLE_ID>\"
  }"

echo "  Done."
echo ""
echo "========================================"
echo "Restore complete. Verify in the portal:"
echo "  https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Permissions/objectId/$SP_ID"
echo "========================================"
