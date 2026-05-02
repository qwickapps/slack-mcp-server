#!/bin/bash
set -e

# Cleanup Dev Builds
# Manages per-commit dev builds on CapRover. Keeps the last N builds and
# deletes older ones, then optionally updates the dev gateway to point to
# the latest surviving build.
#
# Usage:
#   ./cleanup-dev-builds.sh \
#     --app-name-prefix <prefix> \
#     --caprover-url <url> \
#     --caprover-password <password> \
#     [--keep-count <n>] \
#     [--route-caprover-url <url>] \
#     [--route-caprover-password <password>] \
#     [--gateway-app-name <name>] \
#     [--dev-domain-suffix <suffix>]

# Retry wrapper for CapRover API calls
# Usage: caprover_api_call <description> <curl_command...>
caprover_api_call() {
  local description="$1"
  shift
  local max_retries=5
  local retry_delay=10
  local attempt=1

  while [ $attempt -le $max_retries ]; do
    echo "  Attempt $attempt/$max_retries: $description" >&2

    # Execute curl command and capture response
    local response
    response=$("$@")

    # Check if CapRover is busy
    if echo "$response" | grep -iq "another operation.*in progress\|operation.*still in progress\|please wait"; then
      if [ $attempt -lt $max_retries ]; then
        echo "  CapRover is busy with another operation" >&2
        echo "  Waiting ${retry_delay}s before retry..." >&2
        sleep $retry_delay

        # Exponential backoff: double the delay for next retry (max 60s)
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

    # Success - return response (to stdout only)
    echo "$response"
    return 0
  done

  # Should never reach here, but just in case
  return 1
}

# Parse arguments
APP_NAME_PREFIX=""
KEEP_COUNT=3
CAPROVER_URL=""
CAPROVER_PASSWORD=""
ROUTE_CAPROVER_URL=""
ROUTE_CAPROVER_PASSWORD=""
GATEWAY_APP_NAME=""
DEV_DOMAIN_SUFFIX="dev.qwickforge.com"

while [[ $# -gt 0 ]]; do
  case $1 in
    --app-name-prefix)
      APP_NAME_PREFIX="$2"
      shift 2
      ;;
    --keep-count)
      KEEP_COUNT="$2"
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
    --route-caprover-url)
      ROUTE_CAPROVER_URL="$2"
      shift 2
      ;;
    --route-caprover-password)
      ROUTE_CAPROVER_PASSWORD="$2"
      shift 2
      ;;
    --gateway-app-name)
      GATEWAY_APP_NAME="$2"
      shift 2
      ;;
    --dev-domain-suffix)
      DEV_DOMAIN_SUFFIX="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate required arguments
if [ -z "$APP_NAME_PREFIX" ] || [ -z "$CAPROVER_URL" ] || [ -z "$CAPROVER_PASSWORD" ]; then
  echo "Error: Missing required arguments"
  echo "Usage: $0 --app-name-prefix <prefix> --caprover-url <url> --caprover-password <password>"
  exit 1
fi

# Validate route params: all three must be provided together or not at all
ROUTE_PARAMS_COUNT=0
[ -n "$ROUTE_CAPROVER_URL" ] && ROUTE_PARAMS_COUNT=$((ROUTE_PARAMS_COUNT + 1))
[ -n "$ROUTE_CAPROVER_PASSWORD" ] && ROUTE_PARAMS_COUNT=$((ROUTE_PARAMS_COUNT + 1))
[ -n "$GATEWAY_APP_NAME" ] && ROUTE_PARAMS_COUNT=$((ROUTE_PARAMS_COUNT + 1))

if [ "$ROUTE_PARAMS_COUNT" -gt 0 ] && [ "$ROUTE_PARAMS_COUNT" -lt 3 ]; then
  echo "Error: --route-caprover-url, --route-caprover-password, and --gateway-app-name must all be provided together"
  exit 1
fi

UPDATE_GATEWAY=false
if [ "$ROUTE_PARAMS_COUNT" -eq 3 ]; then
  UPDATE_GATEWAY=true
fi

if ! [[ "$KEEP_COUNT" =~ ^[0-9]+$ ]] || [ "$KEEP_COUNT" -lt 1 ]; then
  echo "Error: --keep-count must be a positive integer, got '$KEEP_COUNT'"
  exit 1
fi

echo "========================================="
echo "Cleanup Dev Builds"
echo "========================================="
echo "Prefix: $APP_NAME_PREFIX"
echo "Keep count: $KEEP_COUNT"
echo "CapRover: $CAPROVER_URL"
echo "Gateway update: $UPDATE_GATEWAY"
if [ "$UPDATE_GATEWAY" = true ]; then
  echo "Route CapRover: $ROUTE_CAPROVER_URL"
  echo "Gateway app: $GATEWAY_APP_NAME"
  echo "Dev domain suffix: $DEV_DOMAIN_SUFFIX"
fi
echo "========================================="

# Authenticate with dev CapRover
echo ""
echo "Authenticating with dev CapRover..."
LOGIN_RESPONSE=$(curl -s -k -X POST "$CAPROVER_URL/api/v2/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg pw "$CAPROVER_PASSWORD" '{password: $pw}')")

if ! echo "$LOGIN_RESPONSE" | jq -e . >/dev/null 2>&1; then
  echo "Error: Dev CapRover returned non-JSON response (server may be down)"
  exit 1
fi

LOGIN_STATUS=$(echo "$LOGIN_RESPONSE" | jq -r '.status')
if [ "$LOGIN_STATUS" != "100" ]; then
  echo "Error: Authentication failed with dev CapRover (status: $LOGIN_STATUS)"
  exit 1
fi

DEV_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.data.token')
if [ -z "$DEV_TOKEN" ] || [ "$DEV_TOKEN" = "null" ]; then
  echo "Error: Failed to extract auth token from dev CapRover"
  exit 1
fi

echo "  Authenticated"

# Fetch all app definitions
echo ""
echo "Fetching app definitions..."
APPS_RESPONSE=$(curl -s -k -X GET "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
  -H "x-captain-auth: $DEV_TOKEN")

APPS_STATUS=$(echo "$APPS_RESPONSE" | jq -r '.status')
if [ "$APPS_STATUS" != "100" ]; then
  echo "Error: Failed to fetch app definitions (status: $APPS_STATUS)"
  echo "Response: $APPS_RESPONSE"
  exit 1
fi

echo "  Fetched app definitions"

# Protected names that must never be deleted
PROTECTED_EXACT=(
  "$APP_NAME_PREFIX"
  "${APP_NAME_PREFIX}-dev"
  "${APP_NAME_PREFIX}-uat"
)

# Filter apps matching <APP_NAME_PREFIX>-* and exclude protected names.
# Then sort by the most recent deploy timestamp descending (epoch ms from versions array).
# Apps with no versions get timestamp 0 and sort last.
CANDIDATE_APPS=$(echo "$APPS_RESPONSE" | jq -r \
  --arg prefix "${APP_NAME_PREFIX}-" \
  --argjson protected "$(printf '%s\n' "${PROTECTED_EXACT[@]}" | jq -R . | jq -s .)" \
  '[
    .data.appDefinitions[]
    | select(.appName | startswith($prefix))
    | select(.appName as $n | $protected | index($n) == null)
    | {
        name: .appName,
        ts: (
          if (.versions | length) > 0 then
            (.versions | map(.timeStamp) | max)
          else
            0
          end
        )
      }
  ]
  | sort_by(-.ts)
  | .[]
  | "\(.ts)\t\(.name)"')

if [ -z "$CANDIDATE_APPS" ]; then
  echo ""
  echo "========================================="
  echo "No candidate dev builds found"
  echo "========================================="
  echo "Prefix: ${APP_NAME_PREFIX}-*"
  echo "Nothing to delete."
  echo "========================================="
  exit 0
fi

TOTAL_COUNT=$(echo "$CANDIDATE_APPS" | wc -l | tr -d ' ')
echo ""
echo "Found $TOTAL_COUNT candidate build(s) matching '${APP_NAME_PREFIX}-*':"
echo "$CANDIDATE_APPS" | while IFS=$'\t' read -r ts name; do
  echo "  $name (ts: $ts)"
done

# Split into keep and delete sets
BUILDS_TO_KEEP=()
BUILDS_TO_DELETE=()
INDEX=0

while IFS=$'\t' read -r ts name; do
  INDEX=$((INDEX + 1))
  if [ "$INDEX" -le "$KEEP_COUNT" ]; then
    BUILDS_TO_KEEP+=("$name")
  else
    BUILDS_TO_DELETE+=("$name")
  fi
done <<< "$CANDIDATE_APPS"

echo ""
echo "Keeping $KEEP_COUNT most recent build(s):"
for name in "${BUILDS_TO_KEEP[@]}"; do
  echo "  $name"
done

if [ "${#BUILDS_TO_DELETE[@]}" -eq 0 ]; then
  echo ""
  echo "No builds to delete (total: $TOTAL_COUNT, keep: $KEEP_COUNT)."
else
  echo ""
  echo "Deleting ${#BUILDS_TO_DELETE[@]} older build(s):"
  DELETE_FAILURES=0
  for name in "${BUILDS_TO_DELETE[@]}"; do
    echo "  Deleting $name..."
    DELETE_RESPONSE=$(caprover_api_call "Delete app $name" \
      curl -s -k -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/delete" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: $DEV_TOKEN" \
      -d "$(jq -n --arg name "$name" '{appName: $name}')")

    DELETE_STATUS=$(echo "$DELETE_RESPONSE" | jq -r '.status')
    if [ "$DELETE_STATUS" != "100" ]; then
      DELETE_DESC=$(echo "$DELETE_RESPONSE" | jq -r '.description // "Unknown error"')
      echo "  Warning: Failed to delete $name: $DELETE_DESC (status: $DELETE_STATUS)"
      DELETE_FAILURES=$((DELETE_FAILURES + 1))
      continue
    fi

    echo "    Deleted $name"
  done

  if [ "$DELETE_FAILURES" -gt 0 ]; then
    echo "  Warning: $DELETE_FAILURES deletion(s) failed"
  fi
fi

# Determine the latest surviving build (first in sorted list)
LATEST_BUILD=$(echo "$CANDIDATE_APPS" | head -1 | cut -f2)

echo ""
echo "========================================="
echo "Cleanup complete"
echo "========================================="
echo "Kept:    ${#BUILDS_TO_KEEP[@]} build(s)"
echo "Deleted: ${#BUILDS_TO_DELETE[@]} build(s)"
echo "Latest:  $LATEST_BUILD"
echo "========================================="

# Gateway update (optional)
if [ "$UPDATE_GATEWAY" = false ]; then
  exit 0
fi

LATEST_URL="https://${LATEST_BUILD}.${DEV_DOMAIN_SUFFIX}"

echo ""
echo "========================================="
echo "Updating dev gateway"
echo "========================================="
echo "Gateway app: $GATEWAY_APP_NAME"
echo "Target URL:  $LATEST_URL"
echo "========================================="

# Authenticate with route CapRover
echo ""
echo "Authenticating with route CapRover..."
ROUTE_LOGIN_RESPONSE=$(curl -s -k -X POST "$ROUTE_CAPROVER_URL/api/v2/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg pw "$ROUTE_CAPROVER_PASSWORD" '{password: $pw}')")

if ! echo "$ROUTE_LOGIN_RESPONSE" | jq -e . >/dev/null 2>&1; then
  echo "Error: Route CapRover returned non-JSON response (server may be down)"
  exit 1
fi

ROUTE_LOGIN_STATUS=$(echo "$ROUTE_LOGIN_RESPONSE" | jq -r '.status')
if [ "$ROUTE_LOGIN_STATUS" != "100" ]; then
  echo "Error: Authentication failed with route CapRover (status: $ROUTE_LOGIN_STATUS)"
  exit 1
fi

ROUTE_TOKEN=$(echo "$ROUTE_LOGIN_RESPONSE" | jq -r '.data.token')
if [ -z "$ROUTE_TOKEN" ] || [ "$ROUTE_TOKEN" = "null" ]; then
  echo "Error: Failed to extract auth token from route CapRover"
  exit 1
fi

echo "  Authenticated"

# Fetch the gateway app definition
echo ""
echo "Fetching gateway app definition..."
GATEWAY_RESPONSE=$(curl -s -k -X GET "$ROUTE_CAPROVER_URL/api/v2/user/apps/appDefinitions" \
  -H "x-captain-auth: $ROUTE_TOKEN")

GATEWAY_APPS_STATUS=$(echo "$GATEWAY_RESPONSE" | jq -r '.status')
if [ "$GATEWAY_APPS_STATUS" != "100" ]; then
  echo "Error: Failed to fetch gateway app definitions (status: $GATEWAY_APPS_STATUS)"
  echo "Response: $GATEWAY_RESPONSE"
  exit 1
fi

GATEWAY_APP=$(echo "$GATEWAY_RESPONSE" | jq \
  --arg name "$GATEWAY_APP_NAME" \
  '.data.appDefinitions[] | select(.appName == $name)')

if [ -z "$GATEWAY_APP" ] || [ "$GATEWAY_APP" = "null" ]; then
  echo "Error: Gateway app '$GATEWAY_APP_NAME' not found on route CapRover"
  exit 1
fi

echo "  Found gateway app"

# Build updated env vars array: replace TARGET_APP if present, otherwise append it
UPDATED_ENV_VARS=$(echo "$GATEWAY_APP" | jq \
  --arg url "$LATEST_URL" \
  '
  .envVars as $existing |
  if ($existing | map(select(.key == "TARGET_APP")) | length) > 0 then
    $existing | map(if .key == "TARGET_APP" then .value = $url else . end)
  else
    $existing + [{"key": "TARGET_APP", "value": $url}]
  end
  ')

# Construct the update payload: full read-then-write merge to preserve all fields
UPDATE_PAYLOAD=$(echo "$GATEWAY_APP" | jq \
  --argjson envVars "$UPDATED_ENV_VARS" \
  '.envVars = $envVars')

echo ""
echo "Updating gateway TARGET_APP env var..."
UPDATE_RESPONSE=$(caprover_api_call "Update gateway app definition" \
  curl -s -k -X POST "$ROUTE_CAPROVER_URL/api/v2/user/apps/appDefinitions/update" \
  -H "Content-Type: application/json" \
  -H "x-captain-auth: $ROUTE_TOKEN" \
  -d "$UPDATE_PAYLOAD")

UPDATE_STATUS=$(echo "$UPDATE_RESPONSE" | jq -r '.status')
if [ "$UPDATE_STATUS" != "100" ]; then
  UPDATE_DESC=$(echo "$UPDATE_RESPONSE" | jq -r '.description // "Unknown error"')
  echo "Error: Failed to update gateway app: $UPDATE_DESC (status: $UPDATE_STATUS)"
  exit 1
fi

echo "  Updated TARGET_APP to: $LATEST_URL"

echo ""
echo "========================================="
echo "Gateway update complete"
echo "========================================="
echo "App:        $GATEWAY_APP_NAME"
echo "TARGET_APP: $LATEST_URL"
echo "========================================="
