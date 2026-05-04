#!/usr/bin/env bash
set -euo pipefail

APP_NAME=""
ENVIRONMENT=""
OUTPUT=""

usage() {
  cat >&2 <<'EOF'
Usage:
  write-slack-app-env-file.sh --app-name APP --environment dev|uat|prod --output FILE
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --environment)
      ENVIRONMENT="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$APP_NAME" || -z "$ENVIRONMENT" || -z "$OUTPUT" ]]; then
  usage
  exit 1
fi

case "$ENVIRONMENT" in
  dev|uat|prod) ;;
  *)
    echo "Error: unsupported environment: ${ENVIRONMENT}" >&2
    exit 1
    ;;
esac

env_upper="$(printf '%s' "$ENVIRONMENT" | tr '[:lower:]' '[:upper:]')"

secret() {
  local name="$1"
  printf '%s' "${!name:-}"
}

mask_if_set() {
  local value="$1"
  if [[ -n "$value" ]]; then
    echo "::add-mask::${value}"
  fi
}

mkdir -p "$(dirname "$OUTPUT")"

case "$APP_NAME" in
  slack-mcp-server)
    XOXP_TOKEN="$(secret "SLACK_MCP_SERVER_${env_upper}_XOXP_TOKEN")"
    XOXC_TOKEN="$(secret "SLACK_MCP_SERVER_${env_upper}_XOXC_TOKEN")"
    XOXD_TOKEN="$(secret "SLACK_MCP_SERVER_${env_upper}_XOXD_TOKEN")"
    TS_AUTHKEY="$(secret "SLACK_MCP_SERVER_${env_upper}_TS_AUTHKEY")"
    TS_API_KEY="$(secret "SLACK_MCP_SERVER_${env_upper}_TS_API_KEY")"

    for value in "$XOXP_TOKEN" "$XOXC_TOKEN" "$XOXD_TOKEN" "$TS_AUTHKEY" "$TS_API_KEY"; do
      mask_if_set "$value"
    done

    printf '%s\n' \
      "SLACK_MCP_XOXP_TOKEN=${XOXP_TOKEN}" \
      "SLACK_MCP_XOXC_TOKEN=${XOXC_TOKEN}" \
      "SLACK_MCP_XOXD_TOKEN=${XOXD_TOKEN}" \
      "SLACK_MCP_PORT=13080" \
      "SLACK_MCP_HOST=0.0.0.0" \
      "PORT=13080" \
      "APP_NAME=slack-mcp-server" \
      "TS_AUTHKEY=${TS_AUTHKEY}" \
      "TS_HOSTNAME=slack-mcp-server-${ENVIRONMENT}" \
      "TS_TAGS=tag:container" \
      "TS_API_KEY=${TS_API_KEY}" \
      > "$OUTPUT"
    ;;

  slack-bridge|slack-multiplexer|slack-setup)
    BRIDGE_HMAC_KEY="$(secret "SLACK_MCP_SERVER_${env_upper}_BRIDGE_HMAC_KEY")"
    TOKEN_ENCRYPTION_KEY="$(secret "SLACK_MCP_SERVER_${env_upper}_TOKEN_ENCRYPTION_KEY")"
    MULTIPLEXER_SERVICE_KEY="$(secret "SLACK_MCP_SERVER_${env_upper}_MULTIPLEXER_SERVICE_KEY")"
    SETUP_SERVICE_KEY="$(secret "SLACK_MCP_SERVER_${env_upper}_SETUP_SERVICE_KEY")"
    DATABASE_URL="$(secret "SLACK_MCP_SERVER_${env_upper}_DATABASE_URL")"
    BRIDGE_URL="$(secret "SLACK_MCP_SERVER_${env_upper}_BRIDGE_URL")"
    TS_AUTHKEY="$(secret "SLACK_MCP_SERVER_${env_upper}_TS_AUTHKEY")"
    TS_API_KEY="$(secret "SLACK_MCP_SERVER_${env_upper}_TS_API_KEY")"

    for value in "$BRIDGE_HMAC_KEY" "$TOKEN_ENCRYPTION_KEY" "$MULTIPLEXER_SERVICE_KEY" \
                 "$SETUP_SERVICE_KEY" "$DATABASE_URL" "$BRIDGE_URL" "$TS_AUTHKEY" "$TS_API_KEY"; do
      mask_if_set "$value"
    done

    case "$APP_NAME" in
      slack-bridge)
        printf '%s\n' \
          "BRIDGE_HMAC_KEY=${BRIDGE_HMAC_KEY}" \
          "TOKEN_ENCRYPTION_KEY=${TOKEN_ENCRYPTION_KEY}" \
          "DATABASE_URL=${DATABASE_URL}" \
          "BRIDGE_PORT=13081" \
          "PORT=13081" \
          "APP_NAME=slack-bridge" \
          > "$OUTPUT"
        ;;
      slack-multiplexer)
        printf '%s\n' \
          "TOKEN_ENCRYPTION_KEY=${TOKEN_ENCRYPTION_KEY}" \
          "MULTIPLEXER_SERVICE_KEY=${MULTIPLEXER_SERVICE_KEY}" \
          "DATABASE_URL=${DATABASE_URL}" \
          "MULTIPLEXER_PORT=13082" \
          "PORT=13082" \
          "APP_NAME=slack-multiplexer" \
          "TS_AUTHKEY=${TS_AUTHKEY}" \
          "TS_HOSTNAME=slack-multiplexer-${ENVIRONMENT}" \
          "TS_TAGS=tag:container" \
          "TS_API_KEY=${TS_API_KEY}" \
          > "$OUTPUT"
        ;;
      slack-setup)
        printf '%s\n' \
          "BRIDGE_HMAC_KEY=${BRIDGE_HMAC_KEY}" \
          "SETUP_SERVICE_KEY=${SETUP_SERVICE_KEY}" \
          "DATABASE_URL=${DATABASE_URL}" \
          "BRIDGE_URL=${BRIDGE_URL}" \
          "SETUP_PORT=13083" \
          "PORT=13083" \
          "APP_NAME=slack-setup" \
          "TS_AUTHKEY=${TS_AUTHKEY}" \
          "TS_HOSTNAME=slack-setup-${ENVIRONMENT}" \
          "TS_TAGS=tag:container" \
          "TS_API_KEY=${TS_API_KEY}" \
          > "$OUTPUT"
        ;;
    esac
    ;;

  *)
    echo "Error: unsupported app_name: ${APP_NAME}" >&2
    exit 1
    ;;
esac

echo "Wrote ${OUTPUT} ($(wc -l < "$OUTPUT") lines)"
