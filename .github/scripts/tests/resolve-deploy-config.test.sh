#!/usr/bin/env bash
#
# Tests for .github/scripts/resolve-deploy-config.sh — locks the
# per-app slot/health/image conventions for the four slack apps.
# A regression here silently mis-routes a promotion to the wrong
# CapRover slot, so this contract is worth pinning.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOLVER="$SCRIPTS_DIR/resolve-deploy-config.sh"

pass=0
fail=0
assert() {
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc"
    fail=$((fail + 1))
  fi
}

# Helper — run the resolver and read a single emitted KEY=value pair.
get() {
  local app="$1" env="$2" key="$3"
  unset GITHUB_ENV
  bash "$RESOLVER" --app "$app" --environment "$env" --print 2>/dev/null \
    | awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

# ── Legacy (slack-mcp-server) — preserve exactly ────────────────────────
echo "== legacy slack-mcp-server convention =="

assert "slack-mcp-server prod LIVE_APP=slack-mcp-server-live" \
  bash -c "[ \"\$(bash '$RESOLVER' --app slack-mcp-server --environment prod --print 2>/dev/null | awk -F= '\$1==\"LIVE_APP\"{print \$2}')\" = 'slack-mcp-server-live' ]"

assert "slack-mcp-server prod STABLE_APP=slack-mcp-server-stable (legacy keeps -stable suffix)" \
  bash -c "[ \"\$(bash '$RESOLVER' --app slack-mcp-server --environment prod --print 2>/dev/null | awk -F= '\$1==\"STABLE_APP\"{print \$2}')\" = 'slack-mcp-server-stable' ]"

assert "slack-mcp-server prod HEALTH_PATH=/sse" \
  bash -c "[ \"\$(bash '$RESOLVER' --app slack-mcp-server --environment prod --print 2>/dev/null | awk -F= '\$1==\"HEALTH_PATH\"{print \$2}')\" = '/sse' ]"

assert "slack-mcp-server uat LIVE_APP=slack-mcp-server-uat (legacy: no -live suffix in uat)" \
  bash -c "[ \"\$(bash '$RESOLVER' --app slack-mcp-server --environment uat --print 2>/dev/null | awk -F= '\$1==\"LIVE_APP\"{print \$2}')\" = 'slack-mcp-server-uat' ]"

assert "slack-mcp-server uat STABLE_APP=slack-mcp-server-uat-stable" \
  bash -c "[ \"\$(bash '$RESOLVER' --app slack-mcp-server --environment uat --print 2>/dev/null | awk -F= '\$1==\"STABLE_APP\"{print \$2}')\" = 'slack-mcp-server-uat-stable' ]"

# ── Gap-4 convention for new apps: stable slot is the bare app name ─────
echo "== gap-4 convention (new apps) =="

for app in slack-bridge slack-multiplexer slack-setup; do
  assert "$app prod LIVE_APP=$app-live" \
    bash -c "[ \"\$(bash '$RESOLVER' --app $app --environment prod --print 2>/dev/null | awk -F= '\$1==\"LIVE_APP\"{print \$2}')\" = '${app}-live' ]"

  assert "$app prod STABLE_APP=$app (gap-4: bare app name, no suffix)" \
    bash -c "[ \"\$(bash '$RESOLVER' --app $app --environment prod --print 2>/dev/null | awk -F= '\$1==\"STABLE_APP\"{print \$2}')\" = '${app}' ]"

  assert "$app prod HEALTH_PATH=/health" \
    bash -c "[ \"\$(bash '$RESOLVER' --app $app --environment prod --print 2>/dev/null | awk -F= '\$1==\"HEALTH_PATH\"{print \$2}')\" = '/health' ]"

  assert "$app prod IMAGE_REF_VALIDATOR_PREFIX includes app name" \
    bash -c "bash '$RESOLVER' --app $app --environment prod --print 2>/dev/null | awk -F= '\$1==\"IMAGE_REF_VALIDATOR_PREFIX\"{print \$2}' | grep -q 'img-${app}-'"

  assert "$app prod BASE_IMAGE_NAME ends -prod" \
    bash -c "bash '$RESOLVER' --app $app --environment prod --print 2>/dev/null | awk -F= '\$1==\"BASE_IMAGE_NAME\"{print \$2}' | grep -q 'img-${app}-prod\$'"

  assert "$app prod GATEWAY_APP_NAME=$app (matches stable for new apps)" \
    bash -c "[ \"\$(bash '$RESOLVER' --app $app --environment prod --print 2>/dev/null | awk -F= '\$1==\"GATEWAY_APP_NAME\"{print \$2}')\" = '${app}' ]"
done

# ── No cross-app contamination ──────────────────────────────────────────
echo "== isolation =="

assert "slack-bridge prod IMAGE_REF_VALIDATOR_PREFIX does NOT match slack-mcp-server" \
  bash -c "! bash '$RESOLVER' --app slack-bridge --environment prod --print 2>/dev/null | awk -F= '\$1==\"IMAGE_REF_VALIDATOR_PREFIX\"{print \$2}' | grep -q 'slack-mcp-server'"

assert "slack-multiplexer prod LIVE_APP_URL contains 'slack-multiplexer-live'" \
  bash -c "bash '$RESOLVER' --app slack-multiplexer --environment prod --print 2>/dev/null | awk -F= '\$1==\"LIVE_APP_URL\"{print \$2}' | grep -q 'slack-multiplexer-live\\.app\\.qwickforge\\.com'"

# ── Input validation ────────────────────────────────────────────────────
echo "== input validation =="

assert "missing --app rejects (rc=2)" \
  bash -c "'$RESOLVER' --environment prod --print >/dev/null 2>&1; rc=\$?; test \$rc -eq 2"

assert "missing --environment rejects (rc=2)" \
  bash -c "'$RESOLVER' --app slack-bridge --print >/dev/null 2>&1; rc=\$?; test \$rc -eq 2"

assert "unknown app rejects (rc=2)" \
  bash -c "'$RESOLVER' --app unknown-app --environment prod --print >/dev/null 2>&1; rc=\$?; test \$rc -eq 2"

assert "unknown environment rejects (rc=2)" \
  bash -c "'$RESOLVER' --app slack-bridge --environment dev --print >/dev/null 2>&1; rc=\$?; test \$rc -eq 2"

assert "unknown flag rejects (rc=2)" \
  bash -c "'$RESOLVER' --app slack-bridge --environment prod --bogus --print >/dev/null 2>&1; rc=\$?; test \$rc -eq 2"

# ── Output discipline ───────────────────────────────────────────────────
echo "== output discipline =="

assert "all 9 expected keys present in --print output" \
  bash -c "
    out=\$(bash '$RESOLVER' --app slack-bridge --environment prod --print 2>/dev/null)
    for k in APP_NAME HEALTH_PATH LIVE_APP STABLE_APP LIVE_APP_URL STABLE_APP_URL BASE_IMAGE_NAME IMAGE_REF_VALIDATOR_PREFIX GATEWAY_APP_NAME; do
      echo \"\$out\" | grep -q \"^\${k}=\" || { echo \"missing key: \$k\"; exit 1; }
    done
  "

assert "GITHUB_ENV mode appends without printing to stdout" \
  bash -c "
    tmp=\$(mktemp)
    GITHUB_ENV=\$tmp '$RESOLVER' --app slack-bridge --environment prod >/dev/null 2>&1
    rc=\$?
    [ \$rc -eq 0 ] && grep -q '^APP_NAME=slack-bridge\$' \"\$tmp\"
  "

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
