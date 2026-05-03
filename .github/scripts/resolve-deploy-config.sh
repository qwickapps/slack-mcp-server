#!/usr/bin/env bash
#
# resolve-deploy-config.sh — derive per-app deploy constants for the
# promote-to-live and promote-to-stable workflows. Closes Gap-4 of
# qwickapps/mcp#84 ("promote-to-live.yml + promote-to-stable.yml
# accept app_name as input"): both workflows previously hardcoded
# `slack-mcp-server` and its `/sse` health path; this script
# centralises the per-app config so the same workflows can promote
# any of the four apps in the slack ecosystem.
#
# Usage:
#   ./resolve-deploy-config.sh --app <name> --environment <prod|uat> [--print]
#
# Apps:
#   slack-mcp-server  (legacy — preserves existing slot names exactly)
#   slack-bridge
#   slack-multiplexer
#   slack-setup
#
# When $GITHUB_ENV is set (workflow context), each resolved value is
# written there. Otherwise the values print to stdout in `KEY=value`
# form so tests can capture them.
#
# Exit codes:
#   0  config resolved
#   2  invalid arguments / unknown app / unknown environment

set -euo pipefail

APP=""
ENVIRONMENT=""
PRINT_TO_STDOUT=false

usage() {
  cat >&2 <<USAGE
usage: $0 --app <name> --environment <prod|uat> [--print]

Apps:        slack-mcp-server | slack-bridge | slack-multiplexer | slack-setup
Environments: prod | uat
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)         APP="$2";         shift 2 ;;
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --print)       PRINT_TO_STDOUT=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)
      echo "::error::unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$APP" ] || [ -z "$ENVIRONMENT" ]; then
  echo "::error::--app and --environment are required" >&2
  usage
  exit 2
fi

case "$ENVIRONMENT" in
  prod|uat) ;;
  *)
    echo "::error::invalid --environment '$ENVIRONMENT'; must be prod or uat" >&2
    exit 2
    ;;
esac

APP_NAME=""
HEALTH_PATH=""
LIVE_APP=""
STABLE_APP=""
LIVE_APP_URL=""
STABLE_APP_URL=""
BASE_IMAGE_NAME=""
IMAGE_REF_VALIDATOR_PREFIX=""
GATEWAY_APP_NAME=""

case "$APP" in
  slack-mcp-server)
    # Legacy convention — preserve exactly so the existing operator
    # runbooks keep working. /sse is the MCP SSE endpoint.
    APP_NAME="slack-mcp-server"
    HEALTH_PATH="/sse"
    IMAGE_REF_VALIDATOR_PREFIX="ghcr.io/qwickapps/img-slack-mcp-server-"
    case "$ENVIRONMENT" in
      prod)
        LIVE_APP="${APP_NAME}-live"
        STABLE_APP="${APP_NAME}-stable"
        LIVE_APP_URL="https://${APP_NAME}-live.app.qwickforge.com"
        STABLE_APP_URL="https://${APP_NAME}-stable.app.qwickforge.com"
        BASE_IMAGE_NAME="ghcr.io/qwickapps/img-${APP_NAME}-prod"
        GATEWAY_APP_NAME="${APP_NAME}"
        ;;
      uat)
        LIVE_APP="${APP_NAME}-uat"
        STABLE_APP="${APP_NAME}-uat-stable"
        LIVE_APP_URL="https://${APP_NAME}-uat.app.qwickforge.com"
        STABLE_APP_URL="https://${APP_NAME}-uat-stable.app.qwickforge.com"
        BASE_IMAGE_NAME="ghcr.io/qwickapps/img-${APP_NAME}-uat"
        GATEWAY_APP_NAME="${APP_NAME}-uat"
        ;;
    esac
    ;;

  slack-bridge|slack-multiplexer|slack-setup)
    # Gap-4 convention (per qwickapps/mcp#84): stable slot is the
    # bare app name (no suffix) so the gateway points at the same
    # name as the production app. Live slot is `<app>-live`.
    APP_NAME="$APP"
    HEALTH_PATH="/health"
    IMAGE_REF_VALIDATOR_PREFIX="ghcr.io/qwickapps/img-${APP_NAME}-"
    case "$ENVIRONMENT" in
      prod)
        LIVE_APP="${APP_NAME}-live"
        STABLE_APP="${APP_NAME}"
        LIVE_APP_URL="https://${APP_NAME}-live.app.qwickforge.com"
        STABLE_APP_URL="https://${APP_NAME}.app.qwickforge.com"
        BASE_IMAGE_NAME="ghcr.io/qwickapps/img-${APP_NAME}-prod"
        GATEWAY_APP_NAME="${APP_NAME}"
        ;;
      uat)
        # No explicit uat naming was specified for the new apps in
        # the issue; mirror the legacy pattern (suffix uat slots
        # with -uat / -uat-stable) so behaviour is uniform across
        # the four apps until ops weighs in.
        LIVE_APP="${APP_NAME}-uat"
        STABLE_APP="${APP_NAME}-uat-stable"
        LIVE_APP_URL="https://${APP_NAME}-uat.app.qwickforge.com"
        STABLE_APP_URL="https://${APP_NAME}-uat-stable.app.qwickforge.com"
        BASE_IMAGE_NAME="ghcr.io/qwickapps/img-${APP_NAME}-uat"
        GATEWAY_APP_NAME="${APP_NAME}-uat"
        ;;
    esac
    ;;

  *)
    echo "::error::unknown --app '$APP'; must be one of: slack-mcp-server, slack-bridge, slack-multiplexer, slack-setup" >&2
    exit 2
    ;;
esac

emit() {
  local key="$1" value="$2"
  if [ "$PRINT_TO_STDOUT" = "true" ] || [ -z "${GITHUB_ENV:-}" ]; then
    printf '%s=%s\n' "$key" "$value"
  fi
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_ENV"
  fi
}

emit APP_NAME                   "$APP_NAME"
emit HEALTH_PATH                "$HEALTH_PATH"
emit LIVE_APP                   "$LIVE_APP"
emit STABLE_APP                 "$STABLE_APP"
emit LIVE_APP_URL               "$LIVE_APP_URL"
emit STABLE_APP_URL             "$STABLE_APP_URL"
emit BASE_IMAGE_NAME            "$BASE_IMAGE_NAME"
emit IMAGE_REF_VALIDATOR_PREFIX "$IMAGE_REF_VALIDATOR_PREFIX"
emit GATEWAY_APP_NAME           "$GATEWAY_APP_NAME"
