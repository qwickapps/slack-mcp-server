#!/bin/bash
set -euo pipefail

# Configure CapRover App Script
# Configures app settings: instance count, ports, SSL, HTTPS, env vars
#
# Uses read-then-write: fetches the full current app definition from CapRover
# before updating, so that only the specified fields are changed and all other
# existing settings (volumes, persistent dirs, custom config, etc.) are preserved.
#
# Usage:
#   ./configure-caprover-app.sh \
#     --app-name <name> \
#     --caprover-url <url> \
#     --caprover-password <password> \
#     --instance-count <count> \
#     --container-port <port> \
#     --force-ssl <true|false> \
#     --env-file <path> \
#     [--cmd <binary-path>]
#
# --cmd writes a `serviceUpdateOverride` YAML stanza onto the app definition
# that overrides the container CMD with the given binary path. CapRover does
# not expose CMD as a first-class app field; serviceUpdateOverride is the
# documented escape hatch (see qwickapps/mcp#84). Required when one image
# ships multiple binaries and each CapRover app picks one via CMD (e.g.
# token-bridge / multiplexer / setup all share Dockerfile.qwickapps in
# qwickapps/slack-mcp-server). Pass an absolute binary path. Omit the flag
# entirely to leave any existing override untouched; pass --cmd "" to clear.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib/caprover-api.sh
source "${SCRIPT_DIR}/lib/caprover-api.sh"

# Parse arguments
APP_NAME=""
CAPROVER_URL=""
CAPROVER_PASSWORD=""
INSTANCE_COUNT=1
CONTAINER_PORT=""
FORCE_SSL="true"
ENABLE_SSL="true"
WEBSOCKET_SUPPORT="true"
NOT_EXPOSE_AS_WEB_APP="false"
HAS_PERSISTENT_DATA=""
VOLUMES_JSON=""
PORTS_JSON=""
DESCRIPTION=""
ENV_FILE=""
DOMAINS=""
CMD=""
# Distinguish "flag absent" from "flag passed empty" (= clear override).
# Bash exposes no native sentinel for that, so we track it ourselves.
CMD_SET="false"

while [[ $# -gt 0 ]]; do
  case $1 in
    --app-name)
      APP_NAME="$2"
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
    --instance-count)
      INSTANCE_COUNT="$2"
      shift 2
      ;;
    --container-port)
      CONTAINER_PORT="$2"
      shift 2
      ;;
    --force-ssl)
      FORCE_SSL="$2"
      shift 2
      ;;
    --enable-ssl)
      ENABLE_SSL="$2"
      shift 2
      ;;
    --websocket-support)
      WEBSOCKET_SUPPORT="$2"
      shift 2
      ;;
    --not-expose-as-web-app)
      NOT_EXPOSE_AS_WEB_APP="$2"
      shift 2
      ;;
    --has-persistent-data)
      HAS_PERSISTENT_DATA="$2"
      shift 2
      ;;
    --volumes-json)
      VOLUMES_JSON="$2"
      shift 2
      ;;
    --ports-json)
      PORTS_JSON="$2"
      shift 2
      ;;
    --description)
      DESCRIPTION="$2"
      shift 2
      ;;
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --domains)
      DOMAINS="$2"
      shift 2
      ;;
    --cmd)
      CMD="$2"
      CMD_SET="true"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate required arguments
if [ -z "$APP_NAME" ] || [ -z "$CAPROVER_URL" ] || [ -z "$CAPROVER_PASSWORD" ] || [ -z "$CONTAINER_PORT" ]; then
  echo "Error: Missing required arguments"
  echo "Required: --app-name, --caprover-url, --caprover-password, --container-port"
  exit 1
fi

if ! [[ "$CONTAINER_PORT" =~ ^[0-9]+$ ]] || [ "$CONTAINER_PORT" -lt 1 ] || [ "$CONTAINER_PORT" -gt 65535 ]; then
  echo "Error: --container-port must be an integer from 1 to 65535"
  exit 1
fi

echo "========================================="
echo "Configure CapRover App"
echo "========================================="
echo "App: $APP_NAME"
echo "Instance Count: $INSTANCE_COUNT"
echo "Container Port: $CONTAINER_PORT"
echo "Force SSL: $FORCE_SSL"
[[ -n "$NOT_EXPOSE_AS_WEB_APP" ]] && echo "Internal Service: $NOT_EXPOSE_AS_WEB_APP"
if [ "$CMD_SET" = "true" ]; then
  echo "CMD Override: ${CMD:-<clear>}"
fi
echo "========================================="

# Authenticate with CapRover
echo ""
echo "Authenticating with CapRover..."
TOKEN="$(caprover_login "$CAPROVER_URL" "$CAPROVER_PASSWORD")"
echo "  Authenticated"

CURL_ARGS=()
caprover_populate_curl_args "$CAPROVER_URL" CURL_ARGS

# Ensure app exists
echo ""
echo "Ensuring app exists..."
CREATE_RESPONSE=$(curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/register" \
  -H "Content-Type: application/json" \
  -H "x-captain-auth: $TOKEN" \
  -d "{\"appName\":\"$APP_NAME\",\"hasPersistentData\":false}")

# Check if response is valid JSON
if ! echo "$CREATE_RESPONSE" | jq -e . >/dev/null 2>&1; then
  echo "  Error: Invalid JSON response from CapRover:"
  echo "$CREATE_RESPONSE"
  exit 1
fi

CREATE_STATUS=$(echo "$CREATE_RESPONSE" | jq -r '.status')
APP_ALREADY_EXISTS=false

if [ "$CREATE_STATUS" = "100" ]; then
  echo "  App created"
  APP_ALREADY_EXISTS=false
elif [ "$CREATE_STATUS" = "1901" ]; then
  echo "  App already exists"
  APP_ALREADY_EXISTS=true
else
  DESC=$(echo "$CREATE_RESPONSE" | jq -r '.description')
  if echo "$DESC" | grep -q "already exists"; then
    echo "  App already exists"
    APP_ALREADY_EXISTS=true
  else
    echo "  Warning: Unexpected response: $DESC"
    APP_ALREADY_EXISTS=false
  fi
fi

# Fetch current app definition (read-then-write: preserves all existing fields)
echo ""
echo "Fetching current app definition..."
ALL_DEFS=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
  -H "x-captain-auth: $TOKEN")

CURRENT_DEF=$(echo "$ALL_DEFS" | jq --arg name "$APP_NAME" '.data.appDefinitions[] | select(.appName == $name)')

if [ -z "$CURRENT_DEF" ] || [ "$CURRENT_DEF" = "null" ]; then
  echo "  Error: Could not fetch app definition for $APP_NAME"
  exit 1
fi

echo "  Fetched app definition"

# Step 1: Merge basic settings into current definition (no forceSsl/websocket yet)
# SSL must be enabled before forceSsl can be turned on.
echo ""
echo "Configuring basic app settings..."
MERGED=$(echo "$CURRENT_DEF" | jq \
  --argjson count "$INSTANCE_COUNT" \
  --argjson port "$CONTAINER_PORT" \
  '.instanceCount = $count | .containerHttpPort = $port | .appDeployTokenConfig = (.appDeployTokenConfig // {} | .enabled = true)')

if [ -n "$NOT_EXPOSE_AS_WEB_APP" ]; then
  MERGED=$(echo "$MERGED" | jq --argjson internal "$NOT_EXPOSE_AS_WEB_APP" '.notExposeAsWebApp = $internal')
fi

if [ -n "$HAS_PERSISTENT_DATA" ]; then
  MERGED=$(echo "$MERGED" | jq --argjson persistent "$HAS_PERSISTENT_DATA" '.hasPersistentData = $persistent')
fi

if [ -n "$DESCRIPTION" ]; then
  MERGED=$(echo "$MERGED" | jq --arg description "$DESCRIPTION" '.description = $description')
fi

if [ -n "$VOLUMES_JSON" ]; then
  MERGED=$(echo "$MERGED" | jq --argjson volumes "$VOLUMES_JSON" '.volumes = $volumes')
fi

if [ -n "$PORTS_JSON" ]; then
  MERGED=$(echo "$MERGED" | jq --argjson ports "$PORTS_JSON" '.ports = $ports')
fi

# Apply CMD override via serviceUpdateOverride. The field is a YAML *string*
# embedded inside the JSON definition — CapRover parses it server-side and
# merges into the SwarmKit ServiceSpec on the next deploy. See:
#   https://caprover.com/docs/service-update-override.html
# Only the relevant keys are written; we intentionally do NOT carry over any
# previous serviceUpdateOverride content because the override applies to the
# whole TaskTemplate slice and partial-merging YAML at the app level would
# silently lose other fields a future maintainer might add. If the operator
# needs additional override fields, set them via this flag's input format.
if [ "$CMD_SET" = "true" ]; then
  if [ -z "$CMD" ]; then
    echo ""
    echo "Clearing serviceUpdateOverride (--cmd \"\")..."
    MERGED=$(echo "$MERGED" | jq '.serviceUpdateOverride = ""')
  else
    echo ""
    echo "Setting CMD override via serviceUpdateOverride: $CMD"
    CMD_YAML=$(printf 'TaskTemplate:\n  ContainerSpec:\n    Command:\n      - %s\n' "$CMD")
    MERGED=$(echo "$MERGED" | jq --arg yaml "$CMD_YAML" '.serviceUpdateOverride = $yaml')
  fi
fi

# Merge environment variables if env file provided
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
  echo ""
  echo "Configuring environment variables from $ENV_FILE..."

  # Read env file and convert to JSON array
  ENV_VARS="[]"
  while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue

    # Remove quotes from value if present
    value=$(echo "$value" | sed 's/^["'\'']//' | sed 's/["'\'']$//')

    # Add to JSON array
    ENV_VARS=$(echo "$ENV_VARS" | jq --arg k "$key" --arg v "$value" '. += [{key: $k, value: $v}]')
  done < "$ENV_FILE"

  if [ "$ENV_VARS" != "[]" ]; then
    VAR_COUNT=$(echo "$ENV_VARS" | jq 'length')
    # Merge new variables with existing ones (preserve app-level DATABASE_URL, REDIS_URL, AUTH0 credentials)
    # Extract existing envVars, filter out keys that are being overridden, then append new vars
    ENV_MERGE_SCRIPT=$(cat <<'JQEOF'
.envVars as $existing |
($new_vars | map(.key)) as $new_keys |
($existing // [] | map(select(.key as $k | $new_keys | any(. == $k) | not))) as $kept |
(.envVars = ($kept + $new_vars | sort_by(.key)))
JQEOF
)
    MERGED=$(echo "$MERGED" | jq --argjson new_vars "$ENV_VARS" "$ENV_MERGE_SCRIPT")

    # Safety check: warn if merging would result in very few env vars (likely a data loss situation)
    NEW_ENV_COUNT=$(echo "$MERGED" | jq '.envVars | length')
    if [ "$NEW_ENV_COUNT" -lt 5 ]; then
      echo "  ⚠️  WARNING: Merged env var count is only $NEW_ENV_COUNT (typically 5+ expected)"
      echo "  ⚠️  This may indicate missing DATABASE_URL, REDIS_URL, or AUTH0 credentials"
      echo "  ⚠️  Proceeding, but app may fail to start"
    fi

    echo "  Merged $VAR_COUNT environment variables (preserved existing vars, total now: $NEW_ENV_COUNT)"
  fi
fi

UPDATE_RESPONSE=$(caprover_api_call "Update app (basic settings)" \
  curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/update" \
  -H "Content-Type: application/json" \
  -H "x-captain-auth: $TOKEN" \
  -d "$MERGED")

UPDATE_STATUS=$(echo "$UPDATE_RESPONSE" | jq -r '.status')

if [ "$UPDATE_STATUS" = "100" ] || [ "$UPDATE_STATUS" = "1000" ]; then
  echo "  Basic settings updated"
else
  echo "  Warning: Update response: $(echo "$UPDATE_RESPONSE" | jq -r '.description')"
fi

# Step 2: Enable SSL on the app's base domain before setting forceSsl
echo ""
echo "Enabling SSL on base domain..."
if [ "$ENABLE_SSL" = "true" ] && [ "${NOT_EXPOSE_AS_WEB_APP:-false}" != "true" ]; then
  # Check if SSL is already provisioned before calling Let's Encrypt
  APP_DATA=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appData/$APP_NAME" \
    -H "x-captain-auth: $TOKEN")
  HAS_SSL=$(echo "$APP_DATA" | jq -r '.data.appDefinition.hasDefaultSubDomainSsl // false')

  if [ "$HAS_SSL" = "true" ]; then
    echo "  SSL already provisioned on base domain, skipping"
  else
    SSL_RESPONSE=$(caprover_api_call "Enable base domain SSL" \
      curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/enablebasedomainssl" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: $TOKEN" \
      -d "$(jq -n --arg app "$APP_NAME" '{appName: $app}')")

    SSL_STATUS=$(echo "$SSL_RESPONSE" | jq -r '.status')
    SSL_DESC=$(echo "$SSL_RESPONSE" | jq -r '.description // ""')
    if [ "$SSL_STATUS" = "100" ]; then
      echo "  SSL enabled on base domain"
    elif echo "$SSL_DESC" | grep -iq "already\|enabled"; then
      echo "  SSL already enabled on base domain"
    else
      echo "  Warning: SSL enable response: $SSL_DESC (status: $SSL_STATUS)"
    fi
  fi
else
  if [ "${NOT_EXPOSE_AS_WEB_APP:-false}" = "true" ]; then
    echo "  Internal-only app, skipping base-domain SSL"
  else
    echo "  Base-domain SSL disabled"
  fi
fi

# Step 3: Now enable forceSsl and websocketSupport (SSL is ready)
echo ""
echo "Updating HTTPS and websocket settings..."

# Re-fetch app definition to get latest state after SSL enablement
ALL_DEFS_UPDATED=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
  -H "x-captain-auth: $TOKEN")

CURRENT_DEF_UPDATED=$(echo "$ALL_DEFS_UPDATED" | jq --arg name "$APP_NAME" '.data.appDefinitions[] | select(.appName == $name)')

if [ -z "$CURRENT_DEF_UPDATED" ] || [ "$CURRENT_DEF_UPDATED" = "null" ]; then
  echo "  Warning: Could not re-fetch app definition, using previous"
  CURRENT_DEF_UPDATED="$MERGED"
fi

SSL_MERGED=$(echo "$CURRENT_DEF_UPDATED" | jq \
  --argjson ssl "$FORCE_SSL" \
  --argjson websocket "$WEBSOCKET_SUPPORT" \
  '.forceSsl = $ssl | .websocketSupport = $websocket')

SSL_UPDATE_RESPONSE=$(caprover_api_call "Update app (SSL + websocket)" \
  curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/update" \
  -H "Content-Type: application/json" \
  -H "x-captain-auth: $TOKEN" \
  -d "$SSL_MERGED")

SSL_UPDATE_STATUS=$(echo "$SSL_UPDATE_RESPONSE" | jq -r '.status')

if [ "$SSL_UPDATE_STATUS" = "100" ] || [ "$SSL_UPDATE_STATUS" = "1000" ]; then
  echo "  HTTPS/websocket settings updated"
else
  echo "  Warning: SSL update response: $(echo "$SSL_UPDATE_RESPONSE" | jq -r '.description')"
fi

# Configure custom domains (only for new apps - existing apps keep their domain config)
if [ "${NOT_EXPOSE_AS_WEB_APP:-false}" = "true" ]; then
  echo ""
  echo "Internal-only app, skipping custom domain configuration"
elif [ "$APP_ALREADY_EXISTS" = "false" ] && [ -n "$DOMAINS" ]; then
  echo ""
  echo "Configuring custom domains..."

  IFS=',' read -ra DOMAIN_ARRAY <<< "$DOMAINS"
  for domain in "${DOMAIN_ARRAY[@]}"; do
    domain=$(echo "$domain" | xargs)  # trim whitespace

    echo "  Adding domain: $domain"
    DOMAIN_RESPONSE=$(curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/customdomain" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: $TOKEN" \
      -d "{\"appName\": \"$APP_NAME\", \"customDomain\": \"$domain\"}")

    DOMAIN_STATUS=$(echo "$DOMAIN_RESPONSE" | jq -r '.status')
    if [ "$DOMAIN_STATUS" = "100" ]; then
      echo "    Domain added"
    else
      echo "    $(echo "$DOMAIN_RESPONSE" | jq -r '.description')"
    fi

    # Enable SSL on the custom domain (check first to avoid redundant Let's Encrypt requests)
    echo "  Enabling SSL for $domain..."
    DOMAIN_APP_DATA=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appData/$APP_NAME" \
      -H "x-captain-auth: $TOKEN")
    HAS_CUSTOM_SSL=$(echo "$DOMAIN_APP_DATA" | jq -r --arg dom "$domain" \
      '.data.appDefinition.customDomain[] | select(.publicDomain == $dom) | .hasSsl // false' 2>/dev/null || echo "false")

    if [ "$HAS_CUSTOM_SSL" = "true" ]; then
      echo "    SSL already provisioned for $domain, skipping"
    else
      CUSTOM_SSL_RESPONSE=$(curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/enablecustomdomainssl" \
        -H "Content-Type: application/json" \
        -H "x-captain-auth: $TOKEN" \
        -d "$(jq -n --arg app "$APP_NAME" --arg dom "$domain" '{appName: $app, customDomain: $dom}')")

      CUSTOM_SSL_STATUS=$(echo "$CUSTOM_SSL_RESPONSE" | jq -r '.status')
      if [ "$CUSTOM_SSL_STATUS" = "100" ]; then
        echo "    SSL enabled for $domain"
      else
        echo "    $(echo "$CUSTOM_SSL_RESPONSE" | jq -r '.description')"
      fi
    fi
  done
fi

echo ""
echo "========================================="
echo "Configuration complete"
echo "========================================="
