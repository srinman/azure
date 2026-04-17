# Entra ID Permission Change Runbook

This runbook covers safely changing API permissions on an Enterprise Application in
Entra ID with a backup-and-recovery safety net. Follow the three phases in order.

Before using the scripts, fill in the placeholder values in `backup.sh` and `restore.sh`:

| Placeholder | Where to find it |
|-------------|-----------------|
| `<YOUR_APP_ID>` | Entra portal → App Registrations → your app → **Application (client) ID** |
| `<YOUR_SP_ID>` | Entra portal → Enterprise Applications → your app → **Object ID** (same as SP Object ID — see note below) |
| `<YOUR_TENANT_ID>` | Entra portal → Overview → **Tenant ID** |
| `<your-client-app>` | Display name of your client Enterprise App |
| `<YOUR_API_APP_ID>` | App ID of the API your app calls (from its App Registration) |
| `<YOUR_API_APP_SP_ID>` | Object ID of the API's Enterprise App |
| `<GRAPH_SP_ID>` | Object ID of the Microsoft Graph Enterprise App in your tenant |
| `<YOUR_APP_ROLE_ID>` | ID of the application role (from the API's app manifest → `appRoles[].id`) |
| `<USER_READ_SCOPE_ID>` | ID of the delegated scope (from the API's app manifest → `oauth2PermissionScopes[].id`) |
| `<your-api-app>` | Display name of the API app |

> **Tip — finding GRAPH_SP_ID:**  
> Run `az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv`  
> This is the Microsoft Graph service principal in your tenant.

> **Note — Object ID vs Service Principal ID:**  
> In **Entra portal → Enterprise Applications → Overview**, the field labelled **"Object ID"**
> is the Service Principal's ID — the same value used as `SP_ID` in the scripts. They are identical.
> The App Registration has its own separate Object ID, while **App ID / Client ID** is shared
> between both. See the table below for a quick reference.
>
> | Portal label | Where shown | Used in scripts as |
> |---|---|---|
> | Object ID (Enterprise Applications blade) | Service Principal | `SP_ID` |
> | Object ID (App Registrations blade) | App Registration | *(not used)* |
> | Application (client) ID | Both blades | `APP_ID` |

---

## Files in This Folder

| File | Purpose |
|------|---------|
| `backup.sh` | Phase 1 — queries current permissions and writes a timestamped JSON to `~/bkp/` |
| `restore.sh` | Phase 3 — reverts all permissions back to the baseline hardcoded in the script |

---

## Phase 1 — Back Up Current Permissions

Run this **before making any changes**.

### Pre-requisites
- `az` CLI installed and logged in (`az login`)
- `jq` installed (`sudo apt install jq` or `brew install jq`)
- Account must have at least **Application Administrator** role in the tenant

### Run the backup

```bash
bash backup.sh
```

Each run writes a **new timestamped file** to `~/bkp/`:

```
~/bkp/<your-client-app>-perms-20260417-143022.json
```

Previous backups are never overwritten. List all backups with:

```bash
ls -lth ~/bkp/<your-client-app>-perms-*.json
```

### What gets captured

| Data | Description |
|------|-------------|
| `requiredResourceAccess` | Permissions declared on the App Registration ("API permissions" blade) |
| `oauth2PermissionGrants` | Admin-consented delegated permissions granted to the Enterprise App |
| `appRoleAssignments` | Admin-consented application permissions granted to the Enterprise App |

---

## Phase 2 — Make Your Permission Changes

Make the required changes via whichever method you prefer:

- **Entra portal** — Enterprise Applications → your app → Permissions  
- **App Registration** — App Registrations → your app → API permissions  
- **az CLI / Graph API** — using your own commands

After making changes:
- Verify the app behaves as expected
- Update the **Change Log** table at the bottom of this file
- If everything is working, you are done — no further action needed

---

## Phase 3 — Recovery (only if needed)

If the permission changes cause issues and you need to roll back, run the restore script.

### Pre-requisites
- `az` CLI installed and logged in (`az login`)
- Account must have **Application Administrator** or **Global Administrator** role

### Run the restore

```bash
bash restore.sh
```

### What the restore script does

1. Overwrites `requiredResourceAccess` on the App Registration back to the backup state
2. Deletes all current `oauth2PermissionGrants` on the Enterprise App, then recreates from backup
3. Deletes all current `appRoleAssignments` on the Enterprise App, then recreates from backup

The script is **idempotent** — safe to run multiple times.

### Verify after restore

Check the portal to confirm permissions are back to baseline:  
`https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Permissions/objectId/<YOUR_SP_ID>`

> **Important:** After restoring, any apps or users that acquired tokens under the new
> permissions may have cached tokens. Those will expire naturally (typically within 1 hour
> for access tokens). If you need immediate effect, ask affected users to sign out and
> back in, or clear the token cache in the application.

---

## Change Log

| Date | Change Made | Outcome | Restored? |
|------|-------------|---------|-----------|
| — | Baseline backup captured | — | — |

*(Add a row each time you make a permission change)*

---

## Alternative Approaches

| Approach | Pros | Cons |
|----------|------|------|
| **This runbook (az CLI)** | Fast, no extra tooling, pipeline-friendly | IDs are tenant-specific, not portable across tenants |
| **Export full app manifest** (`az ad app show > manifest.json`) | Captures entire app registration in one file | Restoring the full manifest risks overwriting unrelated settings |
| **Microsoft Graph PowerShell** | Richer automation, official module | Requires PowerShell and Microsoft.Graph SDK installed |
| **Terraform (`azuread` provider)** | Full lifecycle management, `plan` shows diff before apply, git history as audit trail | Higher setup cost; existing apps need `terraform import` to onboard |
| **Entra ID Access Reviews** | Continuous governance, periodic attestation | Not a backup/restore tool — different purpose |

For a long-lived production app, **Terraform** is the recommended long-term approach —
you get version-controlled history, `plan` to preview changes before applying, and `apply`
to revert.
