#!/usr/bin/env bash
set -euo pipefail

# Manual ops script for qwickapps/mcp#81 and qwickapps/mcp#90.
# Corrected SOP: only *-build slots belong on oci-dev. UAT/live/stable belong
# on oci-main. This script removes misplaced live/stable slots from oci-dev
# after an operator reviews the target list and passes --execute.
#
# This script is intentionally not called by any workflow.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib/caprover-api.sh
source "${SCRIPT_DIR}/lib/caprover-api.sh"

CAPROVER_URL="${OCI_DEV_CAPROVER_URL:-}"
CAPROVER_PASSWORD="${OCI_DEV_CAPROVER_PASSWORD:-}"
EXECUTE="false"

usage() {
  cat >&2 <<'EOF'
Usage:
  OCI_DEV_CAPROVER_URL=https://captain.dev.qwickforge.com \
  OCI_DEV_CAPROVER_PASSWORD=... \
  .github/scripts/cleanup-misplaced-slots.sh [--execute]

Default mode is dry-run. Pass --execute only after reviewing the printed list.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute)
      EXECUTE="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$CAPROVER_URL" || -z "$CAPROVER_PASSWORD" ]]; then
  echo "Error: OCI_DEV_CAPROVER_URL and OCI_DEV_CAPROVER_PASSWORD must be set." >&2
  usage
  exit 1
fi

TARGETS=(
  slack-mcp-server-live
  slack-mcp-server-stable
  slack-bridge-live
  slack-bridge-stable
  slack-multiplexer-live
  slack-multiplexer-stable
  slack-setup-live
  slack-setup-stable
)

echo "Corrected SOP cleanup for oci-dev misplaced live/stable slots"
echo "CapRover: ${CAPROVER_URL}"
echo "Mode: $([ "$EXECUTE" = "true" ] && echo execute || echo dry-run)"
echo ""

TOKEN="$(caprover_login "$CAPROVER_URL" "$CAPROVER_PASSWORD")"
CURL_ARGS=()
caprover_populate_curl_args "$CAPROVER_URL" CURL_ARGS

DEFS="$(curl "${CURL_ARGS[@]}" -X GET "${CAPROVER_URL}/api/v2/user/apps/appDefinitions" \
  -H "x-captain-auth: ${TOKEN}")"

for app in "${TARGETS[@]}"; do
  exists="$(echo "$DEFS" | jq -r --arg name "$app" '.data.appDefinitions[]? | select(.appName == $name) | .appName')"
  if [[ -z "$exists" ]]; then
    echo "absent:  ${app}"
    continue
  fi

  if [[ "$EXECUTE" != "true" ]]; then
    echo "would delete: ${app}"
    continue
  fi

  response="$(caprover_api_call "Delete misplaced oci-dev slot ${app}" \
    curl "${CURL_ARGS[@]}" -X POST "${CAPROVER_URL}/api/v2/user/apps/appDefinitions/delete" \
    -H "Content-Type: application/json" \
    -H "x-captain-auth: ${TOKEN}" \
    -d "$(jq -n --arg app "$app" '{appName: $app}')")"
  status="$(echo "$response" | jq -r '.status')"
  if [[ "$status" == "100" || "$status" == "1000" ]]; then
    echo "deleted: ${app}"
  else
    desc="$(echo "$response" | jq -r '.description // "unknown"')"
    echo "failed:  ${app}: ${desc} (status: ${status})" >&2
  fi
done

if [[ "$EXECUTE" != "true" ]]; then
  echo ""
  echo "Dry-run only. Re-run with --execute after ops approval."
fi
