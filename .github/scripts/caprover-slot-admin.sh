#!/usr/bin/env bash
set -euo pipefail

# CapRover slot helpers for the corrected blue-green SOP:
# - wipe dev build slots before reuse
# - scale successful dev build slots to zero
# - read the deployed image digest from a source slot
# - copy runtime config between slots without rebuilding images

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib/caprover-api.sh
source "${SCRIPT_DIR}/lib/caprover-api.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  caprover-slot-admin.sh wipe --app-name APP --caprover-url URL --caprover-password PASS
  caprover-slot-admin.sh scale --app-name APP --instance-count N --caprover-url URL --caprover-password PASS
  caprover-slot-admin.sh image --app-name APP --caprover-url URL --caprover-password PASS
  caprover-slot-admin.sh enable-ssl --app-name APP --caprover-url URL --caprover-password PASS
  caprover-slot-admin.sh copy-config \
    --source-app-name APP --target-app-name APP \
    --source-caprover-url URL --source-caprover-password PASS \
    --target-caprover-url URL --target-caprover-password PASS
EOF
}

command="${1:-}"
if [[ -z "$command" ]]; then
  usage
  exit 1
fi
shift

APP_NAME=""
SOURCE_APP_NAME=""
TARGET_APP_NAME=""
CAPROVER_URL=""
CAPROVER_PASSWORD=""
SOURCE_CAPROVER_URL=""
SOURCE_CAPROVER_PASSWORD=""
TARGET_CAPROVER_URL=""
TARGET_CAPROVER_PASSWORD=""
INSTANCE_COUNT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --source-app-name)
      SOURCE_APP_NAME="$2"
      shift 2
      ;;
    --target-app-name)
      TARGET_APP_NAME="$2"
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
    --source-caprover-url)
      SOURCE_CAPROVER_URL="$2"
      shift 2
      ;;
    --source-caprover-password)
      SOURCE_CAPROVER_PASSWORD="$2"
      shift 2
      ;;
    --target-caprover-url)
      TARGET_CAPROVER_URL="$2"
      shift 2
      ;;
    --target-caprover-password)
      TARGET_CAPROVER_PASSWORD="$2"
      shift 2
      ;;
    --instance-count)
      INSTANCE_COUNT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

login_for() {
  local url="$1"
  local password="$2"
  caprover_login "$url" "$password"
}

get_definition() {
  local url="$1"
  local token="$2"
  local app="$3"
  local curl_args=()
  caprover_populate_curl_args "$url" curl_args

  curl "${curl_args[@]}" -X GET "${url}/api/v2/user/apps/appDefinitions" \
    -H "x-captain-auth: ${token}" \
    | jq --arg name "$app" '.data.appDefinitions[] | select(.appName == $name)'
}

ensure_app() {
  local url="$1"
  local token="$2"
  local app="$3"
  local curl_args=()
  caprover_populate_curl_args "$url" curl_args

  local response status desc
  response=$(caprover_api_call "Register app ${app}" \
    curl "${curl_args[@]}" -X POST "${url}/api/v2/user/apps/appDefinitions/register" \
    -H "Content-Type: application/json" \
    -H "x-captain-auth: ${token}" \
    -d "$(jq -n --arg app "$app" '{appName: $app, hasPersistentData: false}')")

  status=$(echo "$response" | jq -r '.status')
  desc=$(echo "$response" | jq -r '.description // ""')
  if [[ "$status" == "100" || "$status" == "1901" ]] || echo "$desc" | grep -qi "already"; then
    echo "App slot ready: ${app}" >&2
    return 0
  fi

  echo "Error: failed to register ${app}: ${desc} (status: ${status})" >&2
  return 1
}

update_definition() {
  local url="$1"
  local token="$2"
  local payload="$3"
  local description="$4"
  local curl_args=()
  caprover_populate_curl_args "$url" curl_args

  local response status desc
  response=$(caprover_api_call "$description" \
    curl "${curl_args[@]}" -X POST "${url}/api/v2/user/apps/appDefinitions/update" \
    -H "Content-Type: application/json" \
    -H "x-captain-auth: ${token}" \
    -d "$payload")

  status=$(echo "$response" | jq -r '.status')
  if [[ "$status" == "100" || "$status" == "1000" ]]; then
    return 0
  fi

  desc=$(echo "$response" | jq -r '.description // "unknown"')
  echo "Error: ${description} failed: ${desc} (status: ${status})" >&2
  return 1
}

enable_base_domain_ssl() {
  local url="$1"
  local token="$2"
  local app="$3"
  local curl_args=()
  caprover_populate_curl_args "$url" curl_args

  local current has_ssl response status desc refreshed merged
  current="$(get_definition "$url" "$token" "$app")"
  if [[ -z "$current" || "$current" == "null" ]]; then
    echo "Error: app ${app} was not found; cannot enable SSL" >&2
    return 1
  fi

  has_ssl="$(echo "$current" | jq -r '.hasDefaultSubDomainSsl // false')"
  if [[ "$has_ssl" != "true" ]]; then
    response=$(caprover_api_call "Enable base-domain SSL on ${app}" \
      curl "${curl_args[@]}" -X POST "${url}/api/v2/user/apps/appDefinitions/enablebasedomainssl" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: ${token}" \
      -d "$(jq -n --arg app "$app" '{appName: $app}')")
    status="$(echo "$response" | jq -r '.status')"
    desc="$(echo "$response" | jq -r '.description // ""')"
    if [[ "$status" != "100" ]] && ! echo "$desc" | grep -qi "already\|enabled"; then
      echo "Error: SSL enable failed for ${app}: ${desc} (status: ${status})" >&2
      return 1
    fi
  fi

  refreshed="$(get_definition "$url" "$token" "$app")"
  merged="$(echo "$refreshed" | jq '.forceSsl = true | .websocketSupport = true')"
  update_definition "$url" "$token" "$merged" "Set forceSsl/websocketSupport on ${app}"
  echo "Base-domain SSL and forceSsl are enabled for ${app}."
}

case "$command" in
  wipe)
    if [[ -z "$APP_NAME" || -z "$CAPROVER_URL" || -z "$CAPROVER_PASSWORD" ]]; then
      usage
      exit 1
    fi

    token="$(login_for "$CAPROVER_URL" "$CAPROVER_PASSWORD")"
    if ! existing="$(get_definition "$CAPROVER_URL" "$token" "$APP_NAME")"; then
      echo "Error: failed to inspect app definitions for ${APP_NAME}" >&2
      exit 1
    fi

    if [[ -z "$existing" || "$existing" == "null" ]]; then
      echo "Build slot ${APP_NAME} is absent; nothing to wipe."
      exit 0
    fi

    curl_args=()
    caprover_populate_curl_args "$CAPROVER_URL" curl_args
    response=$(caprover_api_call "Delete build slot ${APP_NAME}" \
      curl "${curl_args[@]}" -X POST "${CAPROVER_URL}/api/v2/user/apps/appDefinitions/delete" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: ${token}" \
      -d "$(jq -n --arg app "$APP_NAME" '{appName: $app}')")

    status=$(echo "$response" | jq -r '.status')
    if [[ "$status" != "100" && "$status" != "1000" ]]; then
      desc=$(echo "$response" | jq -r '.description // "unknown"')
      echo "Error: failed to wipe ${APP_NAME}: ${desc} (status: ${status})" >&2
      exit 1
    fi

    echo "Wiped build slot ${APP_NAME}; CapRover will recreate containers and app-scoped volumes on deploy."
    ;;

  scale)
    if [[ -z "$APP_NAME" || -z "$INSTANCE_COUNT" || -z "$CAPROVER_URL" || -z "$CAPROVER_PASSWORD" ]]; then
      usage
      exit 1
    fi
    if ! [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]]; then
      echo "Error: --instance-count must be a non-negative integer" >&2
      exit 1
    fi

    token="$(login_for "$CAPROVER_URL" "$CAPROVER_PASSWORD")"
    current="$(get_definition "$CAPROVER_URL" "$token" "$APP_NAME")"
    if [[ -z "$current" || "$current" == "null" ]]; then
      echo "Error: app ${APP_NAME} was not found; cannot scale" >&2
      exit 1
    fi

    updated="$(echo "$current" | jq --argjson count "$INSTANCE_COUNT" '.instanceCount = $count')"
    update_definition "$CAPROVER_URL" "$token" "$updated" "Scale ${APP_NAME} to ${INSTANCE_COUNT}"
    echo "Scaled ${APP_NAME} to instanceCount=${INSTANCE_COUNT}."
    ;;

  image)
    if [[ -z "$APP_NAME" || -z "$CAPROVER_URL" || -z "$CAPROVER_PASSWORD" ]]; then
      usage
      exit 1
    fi

    token="$(login_for "$CAPROVER_URL" "$CAPROVER_PASSWORD")"
    curl_args=()
    caprover_populate_curl_args "$CAPROVER_URL" curl_args
    app_data="$(curl "${curl_args[@]}" -X GET "${CAPROVER_URL}/api/v2/user/apps/appData/${APP_NAME}" \
      -H "x-captain-auth: ${token}")"
    image_ref="$(echo "$app_data" | jq -r '.data.appDefinition.captainDefinition.imageName // empty')"
    if [[ -z "$image_ref" || "$image_ref" == "null" ]]; then
      echo "Error: could not determine deployed image for ${APP_NAME}" >&2
      exit 1
    fi
    printf '%s\n' "$image_ref"
    ;;

  enable-ssl)
    if [[ -z "$APP_NAME" || -z "$CAPROVER_URL" || -z "$CAPROVER_PASSWORD" ]]; then
      usage
      exit 1
    fi

    token="$(login_for "$CAPROVER_URL" "$CAPROVER_PASSWORD")"
    enable_base_domain_ssl "$CAPROVER_URL" "$token" "$APP_NAME"
    ;;

  copy-config)
    if [[ -z "$SOURCE_APP_NAME" || -z "$TARGET_APP_NAME" || -z "$SOURCE_CAPROVER_URL" || -z "$SOURCE_CAPROVER_PASSWORD" || -z "$TARGET_CAPROVER_URL" || -z "$TARGET_CAPROVER_PASSWORD" ]]; then
      usage
      exit 1
    fi

    source_token="$(login_for "$SOURCE_CAPROVER_URL" "$SOURCE_CAPROVER_PASSWORD")"
    target_token="$(login_for "$TARGET_CAPROVER_URL" "$TARGET_CAPROVER_PASSWORD")"
    ensure_app "$TARGET_CAPROVER_URL" "$target_token" "$TARGET_APP_NAME"

    source_def="$(get_definition "$SOURCE_CAPROVER_URL" "$source_token" "$SOURCE_APP_NAME")"
    target_def="$(get_definition "$TARGET_CAPROVER_URL" "$target_token" "$TARGET_APP_NAME")"
    if [[ -z "$source_def" || "$source_def" == "null" ]]; then
      echo "Error: source app ${SOURCE_APP_NAME} was not found" >&2
      exit 1
    fi
    if [[ -z "$target_def" || "$target_def" == "null" ]]; then
      echo "Error: target app ${TARGET_APP_NAME} was not found after registration" >&2
      exit 1
    fi

    env_vars="$(echo "$source_def" | jq -c '.envVars // []')"
    service_override="$(echo "$source_def" | jq -r '.serviceUpdateOverride // ""')"
    container_port="$(echo "$source_def" | jq -r '.containerHttpPort // empty')"
    internal="$(echo "$source_def" | jq -r '.notExposeAsWebApp // false')"

    merged="$(echo "$target_def" | jq --argjson vars "$env_vars" --argjson internal "$internal" '.envVars = $vars | .notExposeAsWebApp = $internal')"
    if [[ -n "$service_override" ]]; then
      merged="$(echo "$merged" | jq --arg override "$service_override" '.serviceUpdateOverride = $override')"
    fi
    if [[ -n "$container_port" ]]; then
      merged="$(echo "$merged" | jq --argjson port "$container_port" '.containerHttpPort = $port')"
    fi

    update_definition "$TARGET_CAPROVER_URL" "$target_token" "$merged" "Copy config ${SOURCE_APP_NAME} to ${TARGET_APP_NAME}"
    echo "Copied runtime config ${SOURCE_APP_NAME} -> ${TARGET_APP_NAME}."
    ;;

  *)
    echo "Unknown command: $command" >&2
    usage
    exit 1
    ;;
esac
