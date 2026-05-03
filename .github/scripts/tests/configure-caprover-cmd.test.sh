#!/usr/bin/env bash
#
# Unit test for configure-caprover-app.sh --cmd flag (qwickapps/mcp#84).
#
# Strategy: stub `curl` to a function that records the URL + payload of every
# CapRover API call, then drive configure-caprover-app.sh with --cmd and
# assert that the update payload writes a valid serviceUpdateOverride YAML
# stanza targeting the requested binary. Mirrors swap-instances.test.sh.
#
# Run:
#   bash .github/scripts/tests/configure-caprover-cmd.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURE_SCRIPT="$SCRIPTS_DIR/configure-caprover-app.sh"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

CALL_LOG="$TMPDIR_TEST/calls.log"
: >"$CALL_LOG"

# Mock CapRover state — minimal app definition with no existing override.
APP_DEFINITION_JSON=$(cat <<'JSON'
{
  "appName": "slack-bridge-build",
  "envVars": [
    {"key": "EXISTING", "value": "1"}
  ],
  "instanceCount": 1,
  "containerHttpPort": 80,
  "hasDefaultSubDomainSsl": true,
  "forceSsl": false,
  "websocketSupport": false,
  "serviceUpdateOverride": ""
}
JSON
)

ALL_DEFS_JSON=$(jq -n --argjson def "$APP_DEFINITION_JSON" \
  '{data: {appDefinitions: [$def]}}')
ALL_DEFS_FILE="$TMPDIR_TEST/all_defs.json"
echo "$ALL_DEFS_JSON" >"$ALL_DEFS_FILE"

# curl shim — records every call, returns canned CapRover responses.
SHIM_DIR="$TMPDIR_TEST/bin"
mkdir -p "$SHIM_DIR"
cat >"$SHIM_DIR/curl" <<EOF
#!/usr/bin/env bash
LOG="$CALL_LOG"
ALL_DEFS_FILE="$ALL_DEFS_FILE"

url=""
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) shift 2 ;;
    -H) shift 2 ;;
    -d) data="\$2"; shift 2 ;;
    -s|-k|-f|-S|--insecure) shift ;;
    --max-time|--connect-timeout|--retry|--retry-delay|--retry-max-time) shift 2 ;;
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
  */api/v2/user/apps/appDefinitions/register)
    echo '{"status":1901,"description":"app already exists"}'
    ;;
  */api/v2/user/apps/appDefinitions)
    cat "\$ALL_DEFS_FILE"
    ;;
  */api/v2/user/apps/appData/*)
    echo '{"status":100,"data":{"appDefinition":{"hasDefaultSubDomainSsl":true,"customDomain":[]}}}'
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

# Run configure with --cmd
ENV_FILE="$TMPDIR_TEST/app.env"
cat >"$ENV_FILE" <<'ENV'
PORT=13081
ENV

PATH="$SHIM_DIR:$PATH" bash "$CONFIGURE_SCRIPT" \
  --app-name slack-bridge-build \
  --caprover-url https://captain.dev.example.com \
  --caprover-password fakepass \
  --container-port 13081 \
  --env-file "$ENV_FILE" \
  --cmd /usr/local/bin/token-bridge \
  >"$TMPDIR_TEST/run.out" 2>&1 || {
    echo "FAIL: configure-caprover-app.sh exited non-zero with --cmd set"
    cat "$TMPDIR_TEST/run.out"
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

# 1) An update payload was sent that includes serviceUpdateOverride.
OVERRIDE_LINE=$(grep 'appDefinitions/update' "$CALL_LOG" \
  | grep '"serviceUpdateOverride"' \
  | head -n 1 || true)
assert "update payload writes serviceUpdateOverride" \
  test -n "$OVERRIDE_LINE"

if [ -n "$OVERRIDE_LINE" ]; then
  OVERRIDE_PAYLOAD=$(printf '%s' "$OVERRIDE_LINE" | sed 's/.*data=//')

  # 2) The override YAML names the requested binary.
  assert "override pins requested binary" \
    bash -c "echo '$OVERRIDE_PAYLOAD' | jq -e '.serviceUpdateOverride | contains(\"/usr/local/bin/token-bridge\")' >/dev/null"

  # 3) The override is the documented TaskTemplate.ContainerSpec.Command shape.
  assert "override uses TaskTemplate.ContainerSpec.Command shape" \
    bash -c "echo '$OVERRIDE_PAYLOAD' | jq -e '.serviceUpdateOverride | (contains(\"TaskTemplate\") and contains(\"ContainerSpec\") and contains(\"Command\"))' >/dev/null"

  # 4) Existing fields preserved (read-then-write contract).
  assert "preserves containerHttpPort" \
    bash -c "echo '$OVERRIDE_PAYLOAD' | jq -e '.containerHttpPort == 13081' >/dev/null"
  assert "preserves envVars" \
    bash -c "echo '$OVERRIDE_PAYLOAD' | jq -e '.envVars | length > 0' >/dev/null"
fi

# --- Variant 2: --cmd absent → serviceUpdateOverride must NOT be touched ---
CALL_LOG_NOCMD="$TMPDIR_TEST/calls-nocmd.log"
: >"$CALL_LOG_NOCMD"

cat >"$SHIM_DIR/curl" <<EOF
#!/usr/bin/env bash
LOG="$CALL_LOG_NOCMD"
ALL_DEFS_FILE="$ALL_DEFS_FILE"
url=""
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) shift 2 ;;
    -H) shift 2 ;;
    -d) data="\$2"; shift 2 ;;
    -s|-k|-f|-S|--insecure) shift ;;
    --max-time|--connect-timeout|--retry|--retry-delay|--retry-max-time) shift 2 ;;
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
  */api/v2/login) echo '{"status":100,"data":{"token":"fake-token"}}' ;;
  */api/v2/user/apps/appDefinitions/register) echo '{"status":1901}' ;;
  */api/v2/user/apps/appDefinitions) cat "\$ALL_DEFS_FILE" ;;
  */api/v2/user/apps/appData/*) echo '{"status":100,"data":{"appDefinition":{"hasDefaultSubDomainSsl":true,"customDomain":[]}}}' ;;
  */api/v2/user/apps/appDefinitions/update) echo '{"status":100}' ;;
  */api/v2/user/apps/appDefinitions/enablebasedomainssl) echo '{"status":100}' ;;
  *) echo '{"status":100}' ;;
esac
EOF
chmod +x "$SHIM_DIR/curl"

PATH="$SHIM_DIR:$PATH" bash "$CONFIGURE_SCRIPT" \
  --app-name slack-bridge-build \
  --caprover-url https://captain.dev.example.com \
  --caprover-password fakepass \
  --container-port 13081 \
  --env-file "$ENV_FILE" \
  >"$TMPDIR_TEST/run-nocmd.out" 2>&1 || {
    echo "FAIL: configure-caprover-app.sh exited non-zero without --cmd"
    cat "$TMPDIR_TEST/run-nocmd.out"
    exit 1
  }

# When --cmd is omitted, the script must NOT send an update that explicitly
# mentions serviceUpdateOverride (jq's read-then-write preserves whatever
# was on the source, but the "set" branch should not run).
NO_CMD_OVERRIDE_LINE=$(grep 'appDefinitions/update' "$CALL_LOG_NOCMD" \
  | grep '"serviceUpdateOverride":"TaskTemplate' \
  | head -n 1 || true)
assert "no --cmd → script does not write a TaskTemplate override" \
  test -z "$NO_CMD_OVERRIDE_LINE"

echo ""
echo "Tests: $pass passed, $fail failed"
[ $fail -eq 0 ]
