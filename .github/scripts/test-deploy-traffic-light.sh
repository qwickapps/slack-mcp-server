#!/usr/bin/env bash
#
# Unit tests for deploy-traffic-light.sh — issue #20.
#
# Strategy: set SCRIPT_DIR_OVERRIDE to a mock directory so that all sibling
# script calls ($SCRIPT_DIR/deploy-from-ghcr.sh, etc.) resolve to lightweight
# stubs that just log their invocation. A mock `sleep` is prepended to PATH to
# avoid the 60-second stabilization wait. E2E and migrations are disabled via
# flags so the test does not depend on pnpm/playwright.
#
# Test cases:
#   1. dev   — blue-green (qwickapps/mcp#84 retired single-slot dev): must
#              call swap-instances.sh with --direction promote and
#              build/live/stable slot names mirroring prod naming
#   2. uat   — blue-green: must call swap-instances.sh with --direction promote
#              and correct uat slot names
#   3. prod  — blue-green: must call swap-instances.sh with correct prod slot names
#
# Run:
#   bash .github/scripts/test-deploy-traffic-light.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/deploy-traffic-light.sh"

PASS=0
FAIL=0
FAILURES=()

# ── Shared temp dirs ──────────────────────────────────────────────────────────

MOCK_DIR=$(mktemp -d)
LOG_DIR=$(mktemp -d)
export LOG_DIR
trap 'rm -rf "$MOCK_DIR" "$LOG_DIR"' EXIT

# Mock all sibling scripts that deploy-traffic-light.sh calls via $SCRIPT_DIR.
for cmd in deploy-from-ghcr.sh swap-instances.sh validate-deployment-health.sh \
           deep-health-check.sh configure-caprover-app.sh setup-qwickway-route.sh; do
  cat > "$MOCK_DIR/$cmd" <<MOCK
#!/bin/bash
echo "MOCK $cmd \$*" >> "\${LOG_DIR}/calls.log"
exit 0
MOCK
  chmod +x "$MOCK_DIR/$cmd"
done

# Mock sleep so the 60s stabilization wait does not block CI.
cat > "$MOCK_DIR/sleep" <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "$MOCK_DIR/sleep"

# ── Helpers ───────────────────────────────────────────────────────────────────

assert_contains() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  # Use -- to prevent grep from treating patterns starting with -- as flags.
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    return 0
  else
    echo "  FAIL [$label]: expected to find '$pattern'"
    echo "  File contents:"
    sed 's/^/    /' "$file" 2>/dev/null || echo "    (empty or missing)"
    return 1
  fi
}

assert_not_contains() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  # Use -- to prevent grep from treating patterns starting with -- as flags.
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    echo "  FAIL [$label]: expected NOT to find '$pattern'"
    echo "  File contents:"
    sed 's/^/    /' "$file" 2>/dev/null || echo "    (empty or missing)"
    return 1
  else
    return 0
  fi
}

run_test() {
  local name="$1"
  local env="$2"
  shift 2

  : > "$LOG_DIR/calls.log"
  : > "$LOG_DIR/stdout.txt"

  local rc=0
  PATH="$MOCK_DIR:$PATH" \
  SCRIPT_DIR_OVERRIDE="$MOCK_DIR" \
    "$SCRIPT_UNDER_TEST" \
      --product slack-mcp-server \
      --environment "$env" \
      --image-ref "ghcr.io/test/img:1" \
      --caprover-url "https://test.example.com" \
      --caprover-password "test-password" \
      --github-token "test-token" \
      --run-migrations false \
      --run-e2e false \
      "$@" \
    > "$LOG_DIR/stdout.txt" 2>&1 || rc=$?

  echo "$rc" > "$LOG_DIR/last_rc"
  echo "Test: $name (env=$env, rc=$rc)"
}

record_pass() {
  local name="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $name"
}

record_fail() {
  local name="$1"
  FAIL=$((FAIL + 1))
  FAILURES+=("$name")
  echo "  FAIL: $name"
}

# ── Test 1: dev — blue-green (qwickapps/mcp#84) ──────────────────────────────
# Single-slot dev was retired; dev now mirrors prod's full blue-green flow
# with build → live → stable slots and prod-style naming.

run_test "dev-blue-green" "dev"

all_ok=true

assert_contains "dev-blue-green: swap called" \
  "$LOG_DIR/calls.log" "MOCK swap-instances.sh" || all_ok=false

assert_contains "dev-blue-green: direction promote" \
  "$LOG_DIR/calls.log" "--direction promote" || all_ok=false

# Dev now uses prod-style slot naming on the dev CapRover instance.
assert_contains "dev-blue-green: build slot" \
  "$LOG_DIR/stdout.txt" "slack-mcp-server-build" || all_ok=false
assert_contains "dev-blue-green: live slot" \
  "$LOG_DIR/stdout.txt" "slack-mcp-server-live" || all_ok=false
assert_contains "dev-blue-green: stable slot" \
  "$LOG_DIR/stdout.txt" "slack-mcp-server-stable" || all_ok=false

assert_not_contains "dev-blue-green: legacy single-slot message gone" \
  "$LOG_DIR/stdout.txt" "single-slot, skipping swap" || all_ok=false

LAST_RC=$(cat "$LOG_DIR/last_rc")
if [ "$LAST_RC" != "0" ]; then
  echo "  FAIL [dev-blue-green: exit code]: expected 0, got $LAST_RC"
  all_ok=false
fi

if [ "$all_ok" = "true" ]; then
  record_pass "dev-blue-green"
else
  record_fail "dev-blue-green"
fi

# ── Test 2: uat — must call swap with --direction promote + correct slots ─────

run_test "uat-swap-promote" "uat"

all_ok=true

assert_contains "uat-swap-promote: swap called" \
  "$LOG_DIR/calls.log" "MOCK swap-instances.sh" || all_ok=false

assert_contains "uat-swap-promote: direction promote" \
  "$LOG_DIR/calls.log" "--direction promote" || all_ok=false

assert_contains "uat-swap-promote: build slot" \
  "$LOG_DIR/calls.log" "slack-mcp-server-uat-build" || all_ok=false

assert_contains "uat-swap-promote: product arg present" \
  "$LOG_DIR/calls.log" "--product slack-mcp-server" || all_ok=false

if [ "$all_ok" = "true" ]; then
  record_pass "uat-swap-promote"
else
  record_fail "uat-swap-promote"
fi

# ── Test 3: prod — must call swap with correct prod slot names ────────────────

run_test "prod-swap-promote" "prod"

all_ok=true

assert_contains "prod-swap-promote: swap called" \
  "$LOG_DIR/calls.log" "MOCK swap-instances.sh" || all_ok=false

assert_contains "prod-swap-promote: direction promote" \
  "$LOG_DIR/calls.log" "--direction promote" || all_ok=false

assert_contains "prod-swap-promote: build slot" \
  "$LOG_DIR/calls.log" "slack-mcp-server-build" || all_ok=false

assert_contains "prod-swap-promote: product arg present" \
  "$LOG_DIR/calls.log" "--product slack-mcp-server" || all_ok=false

if [ "$all_ok" = "true" ]; then
  record_pass "prod-swap-promote"
else
  record_fail "prod-swap-promote"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "Failed tests:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
fi
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
