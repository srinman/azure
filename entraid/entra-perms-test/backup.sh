#!/usr/bin/env bash
# =============================================================================
# BACKUP SCRIPT — Entra ID App Permissions
# =============================================================================
# Queries the current state of all permissions for your Enterprise App and
# writes a timestamped JSON file to ~/bkp/.
#
# PRE-REQUISITES:
#   - az CLI installed and logged in (az login)
#   - jq installed (used to build the JSON output)
#   - Logged-in account must have at least Application.Read.All in the tenant
#
# USAGE:
#   bash backup.sh
#
# OUTPUT:
#   ~/bkp/<your-client-app>-perms-<YYYYMMDD-HHMMSS>.json
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURE THESE VALUES FOR YOUR APP
# APP_ID   = Application (client) ID from App Registrations blade
# SP_ID    = Object ID from Enterprise Applications blade (same as SP Object ID)
# TENANT_ID = Your Entra tenant ID
# APP_NAME  = Display name used in output file naming
# ---------------------------------------------------------------------------
APP_ID="<YOUR_APP_ID>"
# SP_ID = the "Object ID" shown in Entra portal → Enterprise Applications → Overview.
# The portal labels it "Object ID" (every Entra object has an id), but it IS the
# Service Principal ID. It is different from the App Registration's own Object ID.
SP_ID="<YOUR_SP_ID>"
TENANT_ID="<YOUR_TENANT_ID>"
APP_NAME="<your-client-app>"

BKP_DIR="$HOME/bkp"
mkdir -p "$BKP_DIR"
OUTFILE="$BKP_DIR/${APP_NAME}-perms-$(date +%Y%m%d-%H%M%S).json"

echo "========================================"
echo "Backing up permissions for: $APP_NAME"
echo "App ID: $APP_ID"
echo "SP ID:  $SP_ID"
echo "Output: $OUTFILE"
echo "========================================"
echo ""

# --- 1. requiredResourceAccess from the App Registration --------------------
echo "[1/3] Reading requiredResourceAccess from App Registration..."
REQUIRED=$(az ad app show --id "$APP_ID" --query "requiredResourceAccess" -o json)

# --- 2. oauth2PermissionGrants (delegated consent grants on the SP) ----------
echo "[2/3] Reading oauth2PermissionGrants (delegated permissions)..."
DELEGATED=$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/oauth2PermissionGrants" \
  --query "value[].{clientId:clientId,consentType:consentType,resourceId:resourceId,scope:scope}" \
  -o json)

# --- 3. appRoleAssignments (application permission grants on the SP) ----------
echo "[3/3] Reading appRoleAssignments (application permissions)..."
APP_ROLES=$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignments" \
  --query "value[].{principalId:principalId,resourceId:resourceId,appRoleId:appRoleId}" \
  -o json)

# --- Combine and write output -------------------------------------------------
BACKUP_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg app        "$APP_ID" \
  --arg sp         "$SP_ID" \
  --arg tenant     "$TENANT_ID" \
  --arg appName    "$APP_NAME" \
  --arg backedUpAt "$BACKUP_DATE" \
  --argjson required  "$REQUIRED" \
  --argjson delegated "$DELEGATED" \
  --argjson appRoles  "$APP_ROLES" \
  '{
    "_metadata": {
      "app":              $appName,
      "appId":            $app,
      "servicePrincipalId": $sp,
      "tenantId":         $tenant,
      "backedUpAt":       $backedUpAt
    },
    "requiredResourceAccess": $required,
    "oauth2PermissionGrants":  $delegated,
    "appRoleAssignments":      $appRoles
  }' > "$OUTFILE"

echo ""
echo "========================================"
echo "Backup written to: $OUTFILE"
echo ""
echo "All backups in $BKP_DIR:"
ls -1t "$BKP_DIR/${APP_NAME}-perms-"*.json 2>/dev/null || echo "  (none)"
echo "========================================"
