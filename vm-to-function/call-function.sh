#!/bin/bash

# Function App URL
FUNCTION_APP_URL="${1:-https://your-function-app.azurewebsites.net}"
# App ID from App Registration (you'll pass this as second parameter)
APP_ID="${2}"

if [ -z "$APP_ID" ]; then
    echo "❌ Error: App ID is required"
    echo "Usage: $0 <FUNCTION_APP_URL> <APP_ID>"
    echo "Example: $0 https://func-xxx.azurewebsites.net aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    exit 1
fi

# Use .default scope for simplified authentication
# Both formats work: "api://${APP_ID}/.default" or "${APP_ID}/.default"
RESOURCE="${APP_ID}/.default"

echo "=========================================="
echo "VM to Function App Authentication Test"
echo "=========================================="
echo "Function App URL: $FUNCTION_APP_URL"
echo "Resource (App ID): $APP_ID"
echo "Scope: $RESOURCE (.default scope)"
echo

# Step 1: Get access token from Azure IMDS
echo "Step 1: Getting access token from Azure Instance Metadata Service..."

TOKEN_RESPONSE=$(curl -s -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=${RESOURCE}")

if [ $? -ne 0 ]; then
    echo "❌ Failed to get token from IMDS"
    exit 1
fi

ACCESS_TOKEN=$(echo $TOKEN_RESPONSE | jq -r '.access_token')

if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo "❌ Failed to extract access token"
    echo "Response: $TOKEN_RESPONSE"
    exit 1
fi

echo "✅ Access token obtained"
echo "Token preview: ${ACCESS_TOKEN:0:50}..."

if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo "❌ Failed to extract access token"
    echo "Response: $TOKEN_RESPONSE"
    exit 1
fi

echo "✅ Access token obtained"
echo "Token preview: ${ACCESS_TOKEN:0:50}..."
echo

# Step 2: Call the Function App with the token
echo "Step 2: Calling Function App with access token..."
echo "URL: ${FUNCTION_APP_URL}/api/HttpTrigger"
echo

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  "${FUNCTION_APP_URL}/api/HttpTrigger")

HTTP_STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | sed '/HTTP_STATUS/d')

echo "HTTP Status: $HTTP_STATUS"
echo
echo "Response Body:"
echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
echo

if [ "$HTTP_STATUS" == "200" ]; then
    echo "✅ Successfully authenticated and called Function App!"
else
    echo "❌ Failed to call Function App (HTTP $HTTP_STATUS)"
fi

echo "=========================================="
