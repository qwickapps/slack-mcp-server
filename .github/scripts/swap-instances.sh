#!/bin/bash
set -e

# Swap Instances Script
# Handles traffic light deployment swaps (promote) and rollbacks
#
# Usage:
#   ./swap-instances.sh \
#     --product <name> \
#     --environment <dev|uat|prod> \
#     --direction promote|rollback \
#     --caprover-url <url> \
#     --caprover-password <password> \
#     --github-token <token> \
#     --github-owner <owner> \
#     --build-image-ref <ref>

PRODUCT=""
ENVIRONMENT=""
DIRECTION=""
CAPROVER_URL=""
CAPROVER_PASSWORD=""
GITHUB_TOKEN=""
GITHUB_OWNER="qwickapps"
BUILD_IMAGE_REF=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="$SCRIPT_DIR/deploy-from-ghcr.sh"

while [[ $# -gt 0 ]]; do
  case $1 in
    --product)
      PRODUCT="$2"
      shift 2
      ;;
    --environment)
      ENVIRONMENT="$2"
      shift 2
      ;;
    --direction)
      DIRECTION="$2"
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
    --build-image-ref)
      BUILD_IMAGE_REF="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [ -z "$PRODUCT" ] || [ -z "$ENVIRONMENT" ] || [ -z "$DIRECTION" ]; then
  echo "Error: Missing required arguments"
  echo "Usage: $0 \\"
  echo "  --product <name> \\"
  echo "  --environment <dev|uat|prod> \\"
  echo "  --direction promote|rollback \\"
  echo "  --caprover-url <url> \\"
  echo "  --caprover-password <password> \\"
  echo "  --github-token <token> \\"
  echo "  --build-image-ref <ref>"
  exit 1
fi

if [ "$DIRECTION" != "promote" ] && [ "$DIRECTION" != "rollback" ]; then
  echo "Error: Direction must be 'promote' or 'rollback'"
  exit 1
fi

case $ENVIRONMENT in
  dev)
    # qwickapps/mcp#84: dev now mirrors prod's full blue-green flow.
    # The historical single-slot dev path (BUILD == LIVE, no STABLE)
    # has been retired. Slot apps live on the dev CapRover instance,
    # so the prod-style names cannot collide with prod.
    APP_BUILD="${PRODUCT}-build"
    APP_LIVE="${PRODUCT}-live"
    APP_STABLE="${PRODUCT}-stable"
    ;;
  uat)
    APP_BUILD="${PRODUCT}-uat-build"
    APP_LIVE="${PRODUCT}-uat"
    APP_STABLE="${PRODUCT}-uat-stable"
    ;;
  prod)
    APP_BUILD="${PRODUCT}-build"
    APP_LIVE="${PRODUCT}-live"
    APP_STABLE="${PRODUCT}-stable"
    ;;
  *)
    echo "Error: Invalid environment '$ENVIRONMENT'"
    exit 1
    ;;
esac

echo "========================================="
echo "Swap Instances"
echo "========================================="
echo "Product: $PRODUCT"
echo "Environment: $ENVIRONMENT"
echo "Direction: $DIRECTION"
echo "Build App: $APP_BUILD"
echo "Live App: $APP_LIVE"
echo "Stable App: $APP_STABLE"
echo "========================================="

caprover_api_call() {
  local description="$1"
  shift
  local max_retries=5
  local retry_delay=10
  local attempt=1

  while [ $attempt -le $max_retries ]; do
    echo "  Attempt $attempt/$max_retries: $description" >&2

    local response
    response=$("$@")

    if echo "$response" | grep -iq "another operation.*in progress\|operation.*still in progress\|please wait"; then
      if [ $attempt -lt $max_retries ]; then
        echo "  CapRover is busy with another operation" >&2
        echo "  Waiting ${retry_delay}s before retry..." >&2
        sleep $retry_delay
        retry_delay=$((retry_delay * 2))
        if [ $retry_delay -gt 60 ]; then
          retry_delay=60
        fi
        attempt=$((attempt + 1))
        continue
      else
        echo "  CapRover still busy after $max_retries attempts" >&2
        echo "  Response: $response" >&2
        return 1
      fi
    fi

    echo "$response"
    return 0
  done

  return 1
}

echo ""
echo "Authenticating with CapRover..."
TOKEN=$(curl -s -k -X POST "$CAPROVER_URL/api/v2/login" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"$CAPROVER_PASSWORD\"}" | jq -r '.data.token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Error: Failed to authenticate with CapRover"
  exit 1
fi
echo "  Authenticated"

# Fetch a single app's appDefinition from /appDefinitions (includes envVars).
# /appData omits envVars; only /appDefinitions exposes them.
get_app_definition() {
  local app_name="$1"
  curl -s -k -X GET "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
    -H "x-captain-auth: $TOKEN" \
    | jq --arg name "$app_name" '.data.appDefinitions[] | select(.appName == $name)'
}

# Issue #13: copy envVars from $1 (source app) into $2 (target app) via the
# appDefinitions/update endpoint. Read-then-write: target's other fields are
# preserved. No-op (with warning) when source has zero env vars and no CMD
# override.
#
# qwickapps/mcp#84: also carry over `serviceUpdateOverride` (the CMD override
# slot used when one image ships multiple binaries) so that an override
# written on the build slot via configure-caprover-app.sh --cmd survives
# promotion into live and stable. Without this, only the image is deployed
# forward; the live app would inherit whatever (or no) CMD was on its
# definition, and a multi-binary image layout would silently run the wrong
# binary in the live slot.
copy_env_vars() {
  local src="$1"
  local dst="$2"

  echo "  Reading env vars from source: $src"
  local src_def
  src_def=$(get_app_definition "$src")
  if [ -z "$src_def" ] || [ "$src_def" = "null" ]; then
    echo "  Warning: source app $src not found, skipping env copy"
    return 0
  fi

  local env_vars
  env_vars=$(echo "$src_def" | jq -c '.envVars // []')
  local var_count
  var_count=$(echo "$env_vars" | jq 'length')

  # serviceUpdateOverride is a YAML string ("" when unset). Only carry it
  # forward when non-empty on the source — copying "" could silently clear
  # an override an operator set directly on dst.
  local svc_override
  svc_override=$(echo "$src_def" | jq -r '.serviceUpdateOverride // ""')

  if [ "$var_count" = "0" ] && [ -z "$svc_override" ]; then
    echo "  Warning: source $src has 0 env vars and no CMD override, skipping copy (target $dst may fail to start)"
    return 0
  fi

  echo "  Reading current definition of target: $dst"
  local dst_def
  dst_def=$(get_app_definition "$dst")
  if [ -z "$dst_def" ] || [ "$dst_def" = "null" ]; then
    echo "  Warning: target app $dst not found, skipping env copy"
    return 0
  fi

  local merged
  merged=$(echo "$dst_def" | jq --argjson vars "$env_vars" '.envVars = $vars')

  if [ -n "$svc_override" ]; then
    echo "  Carrying CMD override (serviceUpdateOverride) forward"
    merged=$(echo "$merged" | jq --arg override "$svc_override" '.serviceUpdateOverride = $override')
  fi

  echo "  Writing $var_count env vars to $dst"
  local response
  response=$(caprover_api_call "Copy env vars to $dst" \
    curl -s -k -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/update" \
    -H "Content-Type: application/json" \
    -H "x-captain-auth: $TOKEN" \
    -d "$merged")

  local status
  status=$(echo "$response" | jq -r '.status')
  if [ "$status" = "100" ] || [ "$status" = "1000" ]; then
    echo "  Env vars copied: $src -> $dst ($var_count vars)"
  else
    echo "  Warning: env copy response: $(echo "$response" | jq -r '.description // "unknown"')"
  fi
}

# Issue #15: ensure LE SSL is provisioned on $1's base domain and forceSsl is on.
# Idempotent: enablebasedomainssl returns "already enabled" when SSL is set up
# (same pattern as qwickapps/mcp PR #58 for enablecustomdomainssl).
enable_le_ssl() {
  local app_name="$1"

  if [ -z "$app_name" ]; then
    return 0
  fi

  echo "  Checking SSL state for $app_name"
  local app_def
  app_def=$(get_app_definition "$app_name")
  if [ -z "$app_def" ] || [ "$app_def" = "null" ]; then
    echo "  Warning: app $app_name not found, skipping SSL enable"
    return 0
  fi

  local has_ssl
  has_ssl=$(echo "$app_def" | jq -r '.hasDefaultSubDomainSsl // false')

  # Track whether SSL is genuinely in place. forceSsl must NOT be applied if
  # enablebasedomainssl failed (rate limit, DNS not propagated, ACME challenge
  # failure) — forcing HTTPS on a slot without a cert produces a hard outage
  # because every request fails the TLS handshake.
  local ssl_ok=false

  if [ "$has_ssl" = "true" ]; then
    echo "  SSL already provisioned on base domain for $app_name"
    ssl_ok=true
  else
    echo "  Enabling LE SSL on base domain for $app_name"
    local ssl_response
    ssl_response=$(caprover_api_call "Enable base-domain SSL on $app_name" \
      curl -s -k -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/enablebasedomainssl" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: $TOKEN" \
      -d "$(jq -n --arg app "$app_name" '{appName: $app}')")

    local ssl_status ssl_desc
    ssl_status=$(echo "$ssl_response" | jq -r '.status')
    ssl_desc=$(echo "$ssl_response" | jq -r '.description // ""')
    if [ "$ssl_status" = "100" ]; then
      echo "  SSL enabled on base domain for $app_name"
      ssl_ok=true
    elif echo "$ssl_desc" | grep -iq "already\|enabled"; then
      echo "  SSL already enabled on base domain for $app_name"
      ssl_ok=true
    else
      echo "  ERROR: SSL enable failed for $app_name: $ssl_desc (status: $ssl_status)"
      echo "  Skipping forceSsl update — leaving slot reachable over HTTP to avoid hard outage"
    fi
  fi

  if [ "$ssl_ok" != "true" ]; then
    return 0
  fi

  # Re-fetch and set forceSsl + websocketSupport. Mirrors configure-caprover-app.sh.
  local refreshed
  refreshed=$(get_app_definition "$app_name")
  if [ -z "$refreshed" ] || [ "$refreshed" = "null" ]; then
    echo "  Warning: could not re-fetch $app_name to set forceSsl"
    return 0
  fi

  local force_ssl_def
  force_ssl_def=$(echo "$refreshed" | jq '.forceSsl = true | .websocketSupport = true')

  local update_response
  update_response=$(caprover_api_call "Set forceSsl on $app_name" \
    curl -s -k -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/update" \
    -H "Content-Type: application/json" \
    -H "x-captain-auth: $TOKEN" \
    -d "$force_ssl_def")

  local update_status
  update_status=$(echo "$update_response" | jq -r '.status')
  if [ "$update_status" = "100" ] || [ "$update_status" = "1000" ]; then
    echo "  forceSsl + websocketSupport enabled on $app_name"
  else
    echo "  Warning: forceSsl update response: $(echo "$update_response" | jq -r '.description // "unknown"')"
  fi
}

if [ "$DIRECTION" = "promote" ]; then
  echo ""
  echo "=== PROMOTE: $APP_BUILD → $APP_LIVE ==="

  if [ -z "$BUILD_IMAGE_REF" ]; then
    echo "Error: --build-image-ref required for promote"
    exit 1
  fi

  echo ""
  echo "Step 1: Deploy current build image to stable (as backup)..."
  if [ -n "$APP_STABLE" ]; then
    echo "  Would deploy to $APP_STABLE (stable)"
    echo "  (Skipping stable deployment - keeping previous stable as-is)"
  else
    echo "  No stable app configured for dev environment"
  fi

  echo ""
  echo "Step 2a: Copy env vars from $APP_BUILD to $APP_LIVE (issue #13)..."
  copy_env_vars "$APP_BUILD" "$APP_LIVE"

  if [ -n "$APP_STABLE" ]; then
    echo ""
    echo "Step 2b: Copy env vars from $APP_BUILD to $APP_STABLE (issue #13)..."
    copy_env_vars "$APP_BUILD" "$APP_STABLE"
  fi

  echo ""
  echo "Step 3: Deploy current build image to live..."
  echo "  Deploying $BUILD_IMAGE_REF to $APP_LIVE"

  if [ -f "$DEPLOY_SCRIPT" ]; then
    "$DEPLOY_SCRIPT" \
      --app-name "$APP_LIVE" \
      --image-ref "$BUILD_IMAGE_REF" \
      --caprover-url "$CAPROVER_URL" \
      --caprover-password "$CAPROVER_PASSWORD" \
      --github-token "$GITHUB_TOKEN" \
      --github-owner "$GITHUB_OWNER"
  else
    echo "Error: deploy-from-ghcr.sh not found"
    exit 1
  fi

  echo ""
  echo "Step 4: Wait for live deployment to stabilize..."
  sleep 60

  echo ""
  echo "Step 5: Enable LE SSL on live/stable slots (issue #15)..."
  enable_le_ssl "$APP_LIVE"
  if [ -n "$APP_STABLE" ]; then
    enable_le_ssl "$APP_STABLE"
  fi

  echo ""
  echo "Step 6: Keep build running for potential rollback..."
  echo "  $APP_BUILD remains deployed with new version"

  echo ""
  echo "Promote complete!"
  echo "  Traffic now serving: $APP_LIVE"
  echo "  Previous live is now: $APP_STABLE (if existed)"
  echo "  Rollback available: $APP_BUILD"

elif [ "$DIRECTION" = "rollback" ]; then
  echo ""
  echo "=== ROLLBACK: Restore $APP_STABLE → $APP_LIVE ==="

  if [ -z "$APP_STABLE" ]; then
    echo "Error: No stable app configured for $ENVIRONMENT"
    echo "Cannot rollback - no backup available"
    exit 1
  fi

  echo ""
  echo "Step 1: Verify stable app exists..."
  APP_CHECK=$(curl -s -k -X GET "$CAPROVER_URL/api/v2/user/apps/appData/$APP_STABLE" \
    -H "x-captain-auth: $TOKEN")

  if echo "$APP_CHECK" | jq -e '.data' >/dev/null 2>&1; then
    echo "  Stable app exists: $APP_STABLE"
  else
    echo "Error: Stable app $APP_STABLE not found"
    echo "Cannot rollback - no backup available"
    exit 1
  fi

  echo ""
  echo "Step 2: Get stable app's current image..."
  STABLE_IMAGE=$(echo "$APP_CHECK" | jq -r '.data.appDefinition.captainDefinition.imageName // empty')

  if [ -z "$STABLE_IMAGE" ] || [ "$STABLE_IMAGE" = "null" ]; then
    echo "Error: Could not determine stable app's image"
    exit 1
  fi

  echo "  Stable image: $STABLE_IMAGE"

  echo ""
  echo "Step 3: Deploy stable image to live..."
  if [ -f "$DEPLOY_SCRIPT" ]; then
    "$DEPLOY_SCRIPT" \
      --app-name "$APP_LIVE" \
      --image-ref "$STABLE_IMAGE" \
      --caprover-url "$CAPROVER_URL" \
      --caprover-password "$CAPROVER_PASSWORD" \
      --github-token "$GITHUB_TOKEN" \
      --github-owner "$GITHUB_OWNER"
  else
    echo "Error: deploy-from-ghcr.sh not found"
    exit 1
  fi

  echo ""
  echo "Step 4: Wait for live deployment to stabilize..."
  sleep 60

  echo ""
  echo "Rollback complete!"
  echo "  Traffic restored to: $APP_LIVE (previous stable)"
  echo "  Build marked as failed: $APP_BUILD"

fi

echo ""
echo "========================================="
echo "Swap complete"
echo "========================================="
