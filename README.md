#  Azure 


## Links 

| Description | Link |
|-------------|------|
| Azure Portal - Main dashboard for managing Azure resources | https://portal.azure.com |
| Azure Documentation - Official documentation and tutorials | https://docs.microsoft.com/azure |
| Azure CLI Documentation - Command-line interface guide | https://docs.microsoft.com/cli/azure |
| Azure Status Page - Service health and outages | https://status.azure.com |
| Policy | https://www.azadvertizer.net/index.html |
| Cross region LB | https://github.com/adstuart/azure-crossregion-private-lb?tab=readme-ov-file | 
| EntraID Identity Fundamentals | https://learn.microsoft.com/en-us/entra/fundamentals/identity-fundamental-concepts?toc=%2Fentra%2Fidentity-platform%2Ftoc.json&bc=%2Fentra%2Fidentity-platform%2Fbreadcrumb%2Ftoc.json |  
| VM to Function App auth | [Sample demo](https://github.com/srinman/azure/blob/master/vm-to-function/README.md) |

## 🔒 Security & Best Practices

This repository contains multiple Azure demo projects. To protect sensitive information:

- ✅ **`.gitignore` configured** - Blocks secrets, credentials, and sensitive files across all subfolders
- ✅ **Template files tracked** - Configuration files with placeholder values are safe to commit
- ✅ **Local overrides ignored** - Use `*.local.*` or `.env.local` for real secrets (automatically ignored)

### Working with Secrets

**DO NOT commit:**
- Service principal secrets or passwords
- Connection strings with real credentials
- Azure subscription IDs or tenant IDs in plain text
- SSH private keys
- Certificates (.pfx, .cer, .crt)
- Any `.env` or `.env.*` files (except `.env.example`)

**Safe to commit:**
- Template files with placeholders (e.g., `local.settings.json` with empty values)
- Example files (`.env.example`, `*.example.*`, `*.template.*`)
- Documentation and README files
- Scripts that use environment variables (not hardcoded secrets)

### Recommended Practice

When working on a demo:
1. Use environment variables for all sensitive values
2. Create a `.env.example` file showing required variables (without real values)
3. Document in the demo's README what secrets are needed
4. Use Azure Key Vault or Managed Identities in production scenarios

