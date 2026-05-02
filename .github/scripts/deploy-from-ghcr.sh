#!/bin/bash
set -euo pipefail

# Deploy from GHCR to CapRover
# Configures registry credentials and deploys Docker image from GitHub Container Registry
#
# Usage:
#   ./deploy-from-ghcr.sh \
#     --app-name <name> \
#     --image-ref <ref> \
#     --caprover-url <url> \
#     --caprover-password <password> \
#     --github-token <token> \
#     --github-owner <owner>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib/caprover-api.sh
source "${SCRIPT_DIR}/lib/caprover-api.sh"

# Parse arguments
APP_NAME=""
IMAGE_REF=""
CAPROVER_URL=""
CAPROVER_PASSWORD=""
GITHUB_TOKEN=""
GITHUB_OWNER="${GITHUB_REPOSITORY_OWNER:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --image-ref)
      IMAGE_REF="$2"
      shift 2
      ;;
    --caprover-url)
      CAPROVER_URL="$2"
      shift 2
      ;;
    --caprover-password)
      CAPROVER_PASSWORD="$2"
      shift 2
      ;;
    --github-token)
      GITHUB_TOKEN="$2"
      shift 2
      ;;
    --github-owner)
      GITHUB_OWNER="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate required arguments
if [ -z "$APP_NAME" ] || [ -z "$IMAGE_REF" ] || [ -z "$CAPROVER_URL" ] || [ -z "$CAPROVER_PASSWORD" ] || [ -z "$GITHUB_TOKEN" ]; then
  echo "Error: Missing required arguments"
  echo "Usage: $0 --app-name <name> --image-ref <ref> --caprover-url <url> --caprover-password <password> --github-token <token>"
  exit 1
fi

echo "========================================="
echo "Deploy from GHCR"
echo "========================================="
echo "App: $APP_NAME"
echo "Image: $IMAGE_REF"
echo "CapRover: $CAPROVER_URL"
echo "========================================="

# Authenticate with CapRover
echo ""
echo "Authenticating with CapRover..."
TOKEN="$(caprover_login "$CAPROVER_URL" "$CAPROVER_PASSWORD")"
echo "  ✓ Authenticated"

CURL_ARGS=()
caprover_populate_curl_args "$CAPROVER_URL" CURL_ARGS

# Ensure the target app exists before attempting any deploy.
# CapRover returns status 1106 (App Not Found) when deploying to a non-existent app.
# This block proactively creates it so the deploy never fails for that reason.
# Idempotent: status 1901 = app already exists.
echo ""
echo "Ensuring app exists on CapRover..."
ENSURE_RESPONSE=$(curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/register" \
  -H "Content-Type: application/json" \
  -H "x-captain-auth: $TOKEN" \
  -d "{\"appName\":\"$APP_NAME\",\"hasPersistentData\":false}")
if echo "$ENSURE_RESPONSE" | jq -e . >/dev/null 2>&1; then
  ENSURE_STATUS=$(echo "$ENSURE_RESPONSE" | jq -r ".status")
  if [ "$ENSURE_STATUS" = "100" ]; then
    echo "  App created on CapRover"
  elif [ "$ENSURE_STATUS" = "1901" ]; then
    echo "  App already exists"
  else
    ENSURE_DESC=$(echo "$ENSURE_RESPONSE" | jq -r ".description // \"unknown\"")
    if echo "$ENSURE_DESC" | grep -qi "already exist"; then
      echo "  App already exists"
    else
      echo "  Warning: unexpected register response (status: $ENSURE_STATUS): $ENSURE_DESC"
    fi
  fi
else
  echo "  Warning: non-JSON response when registering app -- proceeding anyway"
fi

# Always refresh GHCR registry credentials in CapRover.
# Stale entries from prior runs cause 500/403 failures during deploy.
# Strategy:
#   Any entries -> UPDATE the first entry with fresh credentials (avoids ghost-entry delete failures)
#   0 entries   -> INSERT a fresh entry
# Note: Ghost entries that cannot be deleted are handled by always updating
# the first valid entry instead of delete+insert.
echo ""
echo "Refreshing GHCR registry credentials..."

REGISTRIES_RESPONSE=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/registries" \
  -H "x-captain-auth: $TOKEN")

EXISTING_IDS=$(echo "$REGISTRIES_RESPONSE" | jq -r '.data.registries[] | select(.registryDomain == "ghcr.io") | .id' 2>/dev/null || true)
ENTRY_COUNT=0
if [ -n "$EXISTING_IDS" ]; then
  ENTRY_COUNT=$(echo "$EXISTING_IDS" | wc -l | tr -d ' ')
fi

if [ "$ENTRY_COUNT" -ge 1 ]; then
  # Update ALL entries with fresh credentials.
  # MW1 CapRover has multiple ghost ghcr.io entries that cannot be deleted (status 1111).
  # CapRover may use any of them when pulling — updating ALL ensures fresh creds regardless.
  echo "  Found $ENTRY_COUNT existing ghcr.io entry(ies) - updating ALL with fresh credentials"
  REGISTRY_RESPONSE=""
  while IFS= read -r registry_id; do
    [ -z "$registry_id" ] && continue
    registry_id=$(echo "$registry_id" | tr -d '[:space:]')
    echo "  Updating entry: $registry_id"
    UPDATE_PAYLOAD=$(jq -n \
      --arg id "$registry_id" \
      --arg user "x-access-token" \
      --arg pass "$GITHUB_TOKEN" \
      --arg domain "ghcr.io" \
      '{id: $id, registryUser: $user, registryPassword: $pass, registryDomain: $domain, registryImagePrefix: ""}')
    ENTRY_RESP=$(caprover_api_call "Update GHCR registry entry $registry_id" \
      curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/registries/update" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: $TOKEN" \
      -d "$UPDATE_PAYLOAD")
    ENTRY_ST=$(echo "$ENTRY_RESP" | jq -r '.status' 2>/dev/null || echo "unknown")
    if [ "$ENTRY_ST" = "100" ]; then
      echo "  ✓ Updated entry $registry_id"
    else
      echo "  ⚠ Update for $registry_id status: $ENTRY_ST ($(echo "$ENTRY_RESP" | jq -r '.description // "?"' 2>/dev/null))"
    fi
    REGISTRY_RESPONSE="$ENTRY_RESP"
  done <<< "$EXISTING_IDS"

else
  echo "  No existing ghcr.io entries - inserting fresh credentials"
  REGISTRY_RESPONSE=$(caprover_api_call "Insert GHCR registry" \
    curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/registries/insert" \
    -H "Content-Type: application/json" \
    -H "x-captain-auth: $TOKEN" \
    -d "$(jq -n \
      --arg user "x-access-token" \
      --arg pass "$GITHUB_TOKEN" \
      --arg domain "ghcr.io" \
      '{registryUser: $user, registryPassword: $pass, registryDomain: $domain, registryImagePrefix: ""}')")
fi

if ! echo "$REGISTRY_RESPONSE" | jq -e . >/dev/null 2>&1; then
  echo "  Error: CapRover returned invalid JSON when updating/adding credentials"
  echo "  Response: $REGISTRY_RESPONSE"
  exit 1
fi

REGISTRY_STATUS=$(echo "$REGISTRY_RESPONSE" | jq -r '.status')
if [ "$REGISTRY_STATUS" != "100" ]; then
  REGISTRY_DESC=$(echo "$REGISTRY_RESPONSE" | jq -r '.description // "Unknown error"')
  echo "  Error: Failed to update/add registry credentials: $REGISTRY_DESC (status: $REGISTRY_STATUS)"
  exit 1
fi

echo "  ✓ Registry credentials updated"

# Deploy from Docker image
echo ""
echo "Deploying from Docker image..."

# Internal helper: build payload and POST to CapRover deploy endpoint.
# CapRover deploy can take longer than nginx proxy_read_timeout (120s),
# causing a 504 even though the deploy continues async in the background.
_do_deploy() {
  local _app="$1"
  local _capt_def
  _capt_def=$(jq -n --arg imageName "$IMAGE_REF" '{schemaVersion: 2, imageName: $imageName}')
  local _payload
  _payload=$(jq -n --argjson captainDef "$_capt_def" '{captainDefinitionContent: ($captainDef | tostring)}')
  caprover_api_call "Deploy Docker image" \
    curl "${CURL_ARGS[@]}" --max-time 300 -X POST "$CAPROVER_URL/api/v2/user/apps/appData/$_app" \
    -H "Content-Type: application/json" \
    -H "x-captain-auth: $TOKEN" \
    -d "$_payload" || true
}

DEPLOY_RESPONSE="$(_do_deploy "$APP_NAME")"

# If CapRover returns status 1106 (App Not Found) despite the register call
# above (e.g. race on a fresh CapRover instance), re-register and retry once.
if echo "$DEPLOY_RESPONSE" | jq -e . >/dev/null 2>&1; then
  if [ "$(echo "$DEPLOY_RESPONSE" | jq -r ".status")" = "1106" ]; then
    echo "  status 1106 (App Not Found) -- re-registering and retrying deploy..."
    curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/register" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: $TOKEN" \
      -d "{\"appName\":\"$APP_NAME\",\"hasPersistentData\":false}" >/dev/null 2>&1 || true
    DEPLOY_RESPONSE="$(_do_deploy "$APP_NAME")"
  fi
fi

if ! echo "$DEPLOY_RESPONSE" | jq -e . >/dev/null 2>&1; then
  # Non-JSON response is either a 504 Gateway Timeout (deploy continues async)
  # or a 500 Internal Server Error (real failure, e.g. stale registry entries).
  # Distinguish them: 500 pages contain "500" or "Internal Server Error".
  if echo "$DEPLOY_RESPONSE" | grep -qi "500\|internal server error"; then
    echo "  Error: CapRover returned HTTP 500 Internal Server Error"
    echo "  This is commonly caused by stale GHCR registry entries in CapRover."
    echo "  Check CapRover's registry settings and remove stale ghcr.io entries."
    echo "  Response (first 10 lines):"
    echo "$DEPLOY_RESPONSE" | head -10
    exit 1
  fi
  echo "  Warning: CapRover returned a non-JSON response (likely 504 timeout)"
  echo "  Response (first 5 lines):"
  echo "$DEPLOY_RESPONSE" | head -5
  echo ""
  echo "  The deploy request was sent. CapRover processes deploys"
  echo "  asynchronously, so the deployment likely continues in the"
  echo "  background. The health check step will verify actual status."
else
  DEPLOY_STATUS=$(echo "$DEPLOY_RESPONSE" | jq -r '.status')
  DEPLOY_DESC=$(echo "$DEPLOY_RESPONSE" | jq -r '.description // ""')

  if [ "$DEPLOY_STATUS" != "100" ] && [ "$DEPLOY_STATUS" != "1000" ]; then
    echo "  Error: Deployment failed"
    echo "  Response: $DEPLOY_RESPONSE"
    exit 1
  fi

  echo "  Deployment triggered successfully"
fi

echo ""
echo "========================================="
echo "Deploy from GHCR complete"
echo "========================================="
echo "Image: $IMAGE_REF"
echo "Next: Health check will verify container started"
echo "========================================="
