#!/bin/bash
# Test script to run on the VM to authenticate and call the Function App
# Uses .default scope for simplified authentication (no app roles needed)

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function App URL and App ID from command line arguments
FUNCTION_APP_URL="${1}"
APP_ID="${2}"

if [ -z "$FUNCTION_APP_URL" ] || [ -z "$APP_ID" ]; then
    echo -e "${RED}Error: Both Function App URL and App ID are required${NC}"
    echo "Usage: $0 <function-app-url> <app-id>"
    echo "Example: $0 https://func-secure-demo-123.azurewebsites.net aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    exit 1
fi

# Remove trailing slash if present
FUNCTION_APP_URL="${FUNCTION_APP_URL%/}"

# Use .default scope for simplified authentication
# Both formats work: "api://${APP_ID}/.default" or "${APP_ID}/.default"
RESOURCE="${APP_ID}/.default"

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}VM to Function App Authentication Test${NC}"
echo -e "${BLUE}==========================================${NC}"
echo -e "${YELLOW}Function App URL:${NC} $FUNCTION_APP_URL"
echo -e "${YELLOW}App ID:${NC} $APP_ID"
echo -e "${YELLOW}Scope:${NC} $RESOURCE ${GREEN}(.default - no app roles!)${NC}"
echo

# Step 1: Get access token from Azure IMDS
echo -e "${BLUE}Step 1: Getting access token from Azure Instance Metadata Service...${NC}"

TOKEN_RESPONSE=$(curl -s -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=${RESOURCE}")

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Failed to get token from IMDS${NC}"
    exit 1
fi

# Check if response contains error
if echo "$TOKEN_RESPONSE" | grep -q "error"; then
    echo -e "${RED}❌ Error getting token:${NC}"
    echo "$TOKEN_RESPONSE" | jq '.'
    exit 1
fi

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')

if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo -e "${RED}❌ Failed to extract access token${NC}"
    echo -e "${YELLOW}Response:${NC}"
    echo "$TOKEN_RESPONSE" | jq '.'
    exit 1
fi

echo -e "${GREEN}✅ Access token obtained${NC}"
echo -e "${YELLOW}Token preview:${NC} ${ACCESS_TOKEN:0:50}..."

# Decode and display token info (optional)
if command -v jq &> /dev/null; then
    echo -e "\n${YELLOW}Token Information:${NC}"
    TOKEN_PAYLOAD=$(echo "$ACCESS_TOKEN" | cut -d'.' -f2)
    # Add padding if needed
    while [ $((${#TOKEN_PAYLOAD} % 4)) -ne 0 ]; do
        TOKEN_PAYLOAD="${TOKEN_PAYLOAD}="
    done
    echo "$TOKEN_PAYLOAD" | base64 -d 2>/dev/null | jq '.' 2>/dev/null || echo "Could not decode token"
fi

echo

# Step 2: Call the Function App with the token
echo -e "${BLUE}Step 2: Calling Function App with access token...${NC}"
echo -e "${YELLOW}URL:${NC} ${FUNCTION_APP_URL}/api/HttpTrigger"
echo

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  "${FUNCTION_APP_URL}/api/HttpTrigger")

HTTP_STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | sed '/HTTP_STATUS/d')

echo -e "${YELLOW}HTTP Status:${NC} $HTTP_STATUS"
echo
echo -e "${YELLOW}Response Body:${NC}"
if command -v jq &> /dev/null; then
    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
else
    echo "$BODY"
fi
echo

# Evaluate result
if [ "$HTTP_STATUS" == "200" ]; then
    echo -e "${GREEN}✅ Successfully authenticated and called Function App!${NC}"
elif [ "$HTTP_STATUS" == "401" ]; then
    echo -e "${RED}❌ Authentication failed (HTTP 401 Unauthorized)${NC}"
    echo -e "${YELLOW}Possible causes:${NC}"
    echo "  - Function App authentication not configured"
    echo "  - Managed identity not assigned to VM"
    echo "  - Token audience mismatch"
elif [ "$HTTP_STATUS" == "403" ]; then
    echo -e "${RED}❌ Access forbidden (HTTP 403 Forbidden)${NC}"
    echo -e "${YELLOW}Possible causes:${NC}"
    echo "  - Managed identity lacks required role assignment"
    echo "  - Function App app role not assigned"
else
    echo -e "${RED}❌ Failed to call Function App (HTTP $HTTP_STATUS)${NC}"
fi

echo -e "${BLUE}==========================================${NC}"

# Exit with appropriate code
if [ "$HTTP_STATUS" == "200" ]; then
    exit 0
else
    exit 1
fi