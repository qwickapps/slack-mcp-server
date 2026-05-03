#!/usr/bin/env bash
#
# Unit test for swap-instances.sh promote helpers (issues #13, #15).
#
# Strategy: stub `curl` to a function that records the URL + payload of every
# CapRover API call to a per-test log file, then drive the swap script against
# the stubbed CapRover and assert the right endpoints were called with the
# right bodies.
#
# Run:
#   bash .github/scripts/tests/swap-instances.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SWAP_SCRIPT="$SCRIPTS_DIR/swap-instances.sh"

# Per-run scratch dir
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

CALL_LOG="$TMPDIR_TEST/calls.log"
: >"$CALL_LOG"

# Mock CapRover state. After qwickapps/mcp#84 dev follows the same
# blue-green slot naming as prod — APP-build, APP-live, APP-stable —
# so the fixture mirrors that. envVars are what we expect to copy
# from build → live; serviceUpdateOverride is the new CMD-override
# field that must also carry forward (#84 real concern).
BUILD_DEFINITION_JSON=$(cat <<'JSON'
{
  "appName": "slack-mcp-server-build",
  "envVars": [
    {"key": "DATABASE_URL", "value": "postgres://db"},
    {"key": "REDIS_URL", "value": "redis://r"},
    {"key": "AUTH0_DOMAIN", "value": "tenant.auth0.com"}
  ],
  "hasDefaultSubDomainSsl": true,
  "forceSsl": true,
  "websocketSupport": true,
  "serviceUpdateOverride": "TaskTemplate:\n  ContainerSpec:\n    Command:\n      - /usr/local/bin/token-bridge\n"
}
JSON
)

LIVE_DEFINITION_JSON=$(cat <<'JSON'
{
  "appName": "slack-mcp-server-live",
  "envVars": [],
  "hasDefaultSubDomainSsl": false,
  "forceSsl": false,
  "websocketSupport": false,
  "serviceUpdateOverride": ""
}
JSON
)

ALL_DEFS_JSON=$(jq -n \
  --argjson build "$BUILD_DEFINITION_JSON" \
  --argjson live "$LIVE_DEFINITION_JSON" \
  '{data: {appDefinitions: [$build, $live]}}')

ALL_DEFS_FILE="$TMPDIR_TEST/all_defs.json"
echo "$ALL_DEFS_JSON" >"$ALL_DEFS_FILE"

# Stub curl. We export it as a function via PATH shim.
SHIM_DIR="$TMPDIR_TEST/bin"
mkdir -p "$SHIM_DIR"
cat >"$SHIM_DIR/curl" <<EOF
#!/usr/bin/env bash
# curl shim — records call and emits canned CapRover JSON.
LOG="$CALL_LOG"
ALL_DEFS_FILE="$ALL_DEFS_FILE"

url=""
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) shift 2 ;;
    -H) shift 2 ;;
    -d) data="\$2"; shift 2 ;;
    -s|-k|-f|-S) shift ;;
    --max-time) shift 2 ;;
    --url) url="\$2"; shift 2 ;;
    http*://*) url="\$1"; shift ;;
    *) shift ;;
  esac
done

# Compact data to a single line so the call log is line-grep-able.
if [ -n "\$data" ]; then
  data_compact=\$(printf '%s' "\$data" | jq -c '.' 2>/dev/null || printf '%s' "\$data" | tr '\n' ' ')
else
  data_compact=""
fi
printf 'CALL\turl=%s\tdata=%s\n' "\$url" "\$data_compact" >>"\$LOG"

case "\$url" in
  */api/v2/login)
    echo '{"status":100,"data":{"token":"fake-token"}}'
    ;;
  */api/v2/user/apps/appDefinitions)
    cat "\$ALL_DEFS_FILE"
    ;;
  */api/v2/user/apps/appDefinitions/update)
    echo '{"status":100,"description":"updated"}'
    ;;
  */api/v2/user/apps/appDefinitions/enablebasedomainssl)
    echo '{"status":100,"description":"ssl enabled"}'
    ;;
  *)
    echo '{"status":100,"description":"ok"}'
    ;;
esac
EOF
chmod +x "$SHIM_DIR/curl"

# Stub the inner deploy script so we don't try to call real CapRover.
DEPLOY_STUB="$TMPDIR_TEST/deploy-from-ghcr.sh"
cat >"$DEPLOY_STUB" <<'EOF'
#!/usr/bin/env bash
echo "deploy-from-ghcr STUB called: $*"
exit 0
EOF
chmod +x "$DEPLOY_STUB"

# swap-instances.sh resolves DEPLOY_SCRIPT from its own dir; copy it next to
# our stub and invoke from there.
WORK_SCRIPTS="$TMPDIR_TEST/scripts"
mkdir -p "$WORK_SCRIPTS/lib"
cp "$SWAP_SCRIPT" "$WORK_SCRIPTS/swap-instances.sh"
cp "$SCRIPTS_DIR/lib/caprover-api.sh" "$WORK_SCRIPTS/lib/caprover-api.sh"
cp "$DEPLOY_STUB" "$WORK_SCRIPTS/deploy-from-ghcr.sh"

# Make sleep a no-op so the test runs in <1s.
cat >"$SHIM_DIR/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SHIM_DIR/sleep"

# Run the swap in promote mode against the stubbed CapRover.
PATH="$SHIM_DIR:$PATH" bash "$WORK_SCRIPTS/swap-instances.sh" \
  --product slack-mcp-server \
  --environment dev \
  --direction promote \
  --caprover-url https://captain.dev.example.com \
  --caprover-password fakepass \
  --github-token fake-gh \
  --build-image-ref ghcr.io/qwickapps/img-slack-dev:1.0.0 \
  >"$TMPDIR_TEST/swap.out" 2>&1 || {
    echo "FAIL: swap-instances.sh exited non-zero"
    cat "$TMPDIR_TEST/swap.out"
    exit 1
  }

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

# --- Issue #13 assertions: env vars copied from build -> live ---

# 1) The update endpoint was called against /appDefinitions/update
assert "update endpoint called for env copy" \
  grep -q 'url=https://captain.dev.example.com/api/v2/user/apps/appDefinitions/update' "$CALL_LOG"

# 2) An update payload referenced the live app and contains all 3 env keys
ENV_UPDATE_LINE=$(grep 'appDefinitions/update' "$CALL_LOG" \
  | grep 'slack-mcp-server-live' \
  | grep '"envVars"' \
  | head -n 1 || true)

assert "env-copy update targets live slot with envVars" \
  test -n "$ENV_UPDATE_LINE"

if [ -n "$ENV_UPDATE_LINE" ]; then
  ENV_PAYLOAD=$(printf '%s' "$ENV_UPDATE_LINE" | sed 's/.*data=//')
  assert "envVars contains DATABASE_URL" \
    bash -c "echo '$ENV_PAYLOAD' | jq -e '.envVars[] | select(.key == \"DATABASE_URL\")' >/dev/null"
  assert "envVars contains REDIS_URL" \
    bash -c "echo '$ENV_PAYLOAD' | jq -e '.envVars[] | select(.key == \"REDIS_URL\")' >/dev/null"
  assert "envVars contains AUTH0_DOMAIN" \
    bash -c "echo '$ENV_PAYLOAD' | jq -e '.envVars[] | select(.key == \"AUTH0_DOMAIN\")' >/dev/null"
fi

# --- Issue #15 assertions: LE SSL enabled on live slot ---

assert "enablebasedomainssl called" \
  grep -q 'url=https://captain.dev.example.com/api/v2/user/apps/appDefinitions/enablebasedomainssl' "$CALL_LOG"

SSL_BODY_LINE=$(grep 'appDefinitions/enablebasedomainssl' "$CALL_LOG" | head -n 1 || true)
if [ -n "$SSL_BODY_LINE" ]; then
  SSL_PAYLOAD=$(printf '%s' "$SSL_BODY_LINE" | sed 's/.*data=//')
  assert "enablebasedomainssl payload targets live slot" \
    bash -c "echo '$SSL_PAYLOAD' | jq -e '.appName == \"slack-mcp-server-live\"' >/dev/null"
fi

# 3) forceSsl=true update was sent for the live slot
FORCE_SSL_LINE=$(grep 'appDefinitions/update' "$CALL_LOG" \
  | grep 'slack-mcp-server-live' \
  | grep '"forceSsl":true' \
  | head -n 1 || true)
assert "forceSsl=true update sent for live slot" \
  test -n "$FORCE_SSL_LINE"

# qwickapps/mcp#84: serviceUpdateOverride must carry forward from build
# to live during env-var copy. Without this, a CMD override written via
# configure-caprover-app.sh --cmd would survive only on the build slot;
# the live slot would inherit whatever (or no) CMD was on its own
# definition and a single-image-multiple-binaries layout would silently
# run the wrong binary.
SERVICE_OVERRIDE_LINE=$(grep 'appDefinitions/update' "$CALL_LOG" \
  | grep 'slack-mcp-server-live' \
  | grep '"envVars"' \
  | grep '"serviceUpdateOverride"' \
  | head -n 1 || true)
assert "serviceUpdateOverride carries from build to live" \
  test -n "$SERVICE_OVERRIDE_LINE"
if [ -n "$SERVICE_OVERRIDE_LINE" ]; then
  SERVICE_OVERRIDE_PAYLOAD=$(printf '%s' "$SERVICE_OVERRIDE_LINE" | sed 's/.*data=//')
  assert "carried-forward override pins token-bridge binary" \
    bash -c "echo '$SERVICE_OVERRIDE_PAYLOAD' | jq -e '.serviceUpdateOverride | contains(\"/usr/local/bin/token-bridge\")' >/dev/null"
fi

# --- Order assertion: env-copy must run BEFORE deploy stub (so live boots
# with correct env). The shim doesn't see deploy directly, but the env-copy
# update must precede the SSL enable call.
ENV_LINENUM=$(grep -n 'appDefinitions/update' "$CALL_LOG" \
  | grep 'slack-mcp-server-live' \
  | grep '"envVars"' \
  | head -n 1 | cut -d: -f1 || true)
SSL_LINENUM=$(grep -n 'appDefinitions/enablebasedomainssl' "$CALL_LOG" \
  | head -n 1 | cut -d: -f1 || true)

if [ -n "$ENV_LINENUM" ] && [ -n "$SSL_LINENUM" ]; then
  assert "env copy occurs before SSL enable" \
    test "$ENV_LINENUM" -lt "$SSL_LINENUM"
fi

# --- Issue #18 BLOCKING: SSL enable failure must NOT trigger forceSsl ---
#
# Re-run the swap with a curl shim that returns a failed enablebasedomainssl
# response (e.g. LE rate limit). Assert that no forceSsl=true update is sent
# for the live slot, otherwise the slot would become unreachable.

CALL_LOG_FAIL="$TMPDIR_TEST/calls-ssl-fail.log"
: >"$CALL_LOG_FAIL"

cat >"$SHIM_DIR/curl" <<EOF
#!/usr/bin/env bash
# curl shim — SSL-failure variant: enablebasedomainssl returns a rate-limit error.
LOG="$CALL_LOG_FAIL"
ALL_DEFS_FILE="$ALL_DEFS_FILE"

url=""
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) shift 2 ;;
    -H) shift 2 ;;
    -d) data="\$2"; shift 2 ;;
    -s|-k|-f|-S) shift ;;
    --max-time) shift 2 ;;
    --url) url="\$2"; shift 2 ;;
    http*://*) url="\$1"; shift ;;
    *) shift ;;
  esac
done

if [ -n "\$data" ]; then
  data_compact=\$(printf '%s' "\$data" | jq -c '.' 2>/dev/null || printf '%s' "\$data" | tr '\n' ' ')
else
  data_compact=""
fi
printf 'CALL\turl=%s\tdata=%s\n' "\$url" "\$data_compact" >>"\$LOG"

case "\$url" in
  */api/v2/login)
    echo '{"status":100,"data":{"token":"fake-token"}}'
    ;;
  */api/v2/user/apps/appDefinitions)
    cat "\$ALL_DEFS_FILE"
    ;;
  */api/v2/user/apps/appDefinitions/update)
    echo '{"status":100,"description":"updated"}'
    ;;
  */api/v2/user/apps/appDefinitions/enablebasedomainssl)
    # Simulate Let's Encrypt failure (rate limit / DNS not propagated).
    echo '{"status":1106,"description":"acme: rate limit exceeded"}'
    ;;
  *)
    echo '{"status":100,"description":"ok"}'
    ;;
esac
EOF
chmod +x "$SHIM_DIR/curl"

PATH="$SHIM_DIR:$PATH" bash "$WORK_SCRIPTS/swap-instances.sh" \
  --product slack-mcp-server \
  --environment dev \
  --direction promote \
  --caprover-url https://captain.dev.example.com \
  --caprover-password fakepass \
  --github-token fake-gh \
  --build-image-ref ghcr.io/qwickapps/img-slack-dev:1.0.0 \
  >"$TMPDIR_TEST/swap-ssl-fail.out" 2>&1 || {
    echo "FAIL: swap-instances.sh (ssl-fail variant) exited non-zero"
    cat "$TMPDIR_TEST/swap-ssl-fail.out"
    exit 1
  }

# enablebasedomainssl was attempted
assert "ssl-fail: enablebasedomainssl was attempted" \
  grep -q 'url=https://captain.dev.example.com/api/v2/user/apps/appDefinitions/enablebasedomainssl' "$CALL_LOG_FAIL"

# CRITICAL: no forceSsl=true update was sent for the live slot, because SSL
# enable failed. Otherwise the slot would be unreachable over HTTPS.
FORCE_SSL_LINE_FAIL=$(grep 'appDefinitions/update' "$CALL_LOG_FAIL" \
  | grep 'slack-mcp-server-live' \
  | grep '"forceSsl":true' \
  | head -n 1 || true)
assert "ssl-fail: forceSsl=true must NOT be sent when SSL enable failed" \
  test -z "$FORCE_SSL_LINE_FAIL"

# The error must surface visibly in the log (no silent continuation).
assert "ssl-fail: error is logged" \
  grep -q 'SSL enable failed' "$TMPDIR_TEST/swap-ssl-fail.out"

echo ""
echo "Tests: $pass passed, $fail failed"
[ $fail -eq 0 ]
