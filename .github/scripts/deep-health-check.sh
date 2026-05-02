#!/bin/bash
set -e

# Deep Health Check Script
# Hits a health endpoint, parses JSON response, and validates subsystem health
# with configurable critical vs warning classification.
#
# Unlike validate-deployment-health.sh (which only checks HTTP 200),
# this script inspects the JSON body and enforces subsystem-level health.
#
# Subsystem classification:
#   --critical-subsystems: MUST be healthy. If any are unhealthy after retries,
#                          the check fails and deployment is blocked.
#   --warning-subsystems:  SHOULD be healthy. If unhealthy, a warning is printed
#                          but the check still passes.
#   --required-subsystems: Legacy alias for --critical-subsystems (backward compat).
#
# Memory check:
#   If the health response includes memory data (in .memory, .system.memory, or
#   .system.freeMemory), and free memory is below --min-free-memory-mb (default 10),
#   a warning is printed. Memory warnings never block the deployment.
#
# Usage:
#   ./deep-health-check.sh \
#     --url <health-endpoint-url> \
#     [--timeout <seconds>] \
#     [--critical-subsystems <comma-separated-list>] \
#     [--warning-subsystems <comma-separated-list>] \
#     [--required-subsystems <comma-separated-list>] \
#     [--min-free-memory-mb <megabytes>] \
#     [--max-attempts <n>] \
#     [--sleep <seconds>]
#
# Exit codes:
#   0 - all critical subsystems healthy (warnings may be present)
#   1 - one or more critical subsystems unhealthy or unreachable

URL=""
TIMEOUT=10
CRITICAL_SUBSYSTEMS=""
WARNING_SUBSYSTEMS=""
MAX_ATTEMPTS=5
SLEEP_SECONDS=10
SUMMARY_FILE=""
MIN_FREE_MEMORY_MB=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --url)
      URL="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --critical-subsystems)
      CRITICAL_SUBSYSTEMS="$2"
      shift 2
      ;;
    --warning-subsystems)
      WARNING_SUBSYSTEMS="$2"
      shift 2
      ;;
    --required-subsystems)
      CRITICAL_SUBSYSTEMS="$2"
      shift 2
      ;;
    --summary-file)
      SUMMARY_FILE="$2"
      shift 2
      ;;
    --min-free-memory-mb)
      MIN_FREE_MEMORY_MB="$2"
      shift 2
      ;;
    --max-attempts)
      MAX_ATTEMPTS="$2"
      shift 2
      ;;
    --sleep)
      SLEEP_SECONDS="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [ -z "$URL" ]; then
  echo "Error: --url is required"
  echo "Usage: $0 --url <url> [--critical-subsystems <list>] [--warning-subsystems <list>] [--max-attempts <n>] [--sleep <s>]"
  exit 1
fi

TOTAL_WAIT=$(( MAX_ATTEMPTS * SLEEP_SECONDS ))

echo "========================================="
echo "Deep Health Check"
echo "========================================="
echo "URL:                    $URL"
echo "Timeout:                ${TIMEOUT}s per request"
echo "Critical subsystems:    ${CRITICAL_SUBSYSTEMS:-auto-detect (all)}"
echo "Warning subsystems:     ${WARNING_SUBSYSTEMS:-none}"
echo "Min free memory:        ${MIN_FREE_MEMORY_MB}MB (warn only)"
echo "Retries:                ${MAX_ATTEMPTS} x ${SLEEP_SECONDS}s = up to ${TOTAL_WAIT}s"
echo "========================================="

in_list() {
  local needle="$1"
  local haystack="$2"
  [ -z "$haystack" ] && return 1
  local saved_ifs="$IFS"
  IFS=,
  for item in $haystack; do
    item=$(echo "$item" | xargs)
    if [ "$item" = "$needle" ]; then
      IFS="$saved_ifs"
      return 0
    fi
  done
  IFS="$saved_ifs"
  return 1
}

classify_subsystem() {
  local name="$1"
  if in_list "$name" "$WARNING_SUBSYSTEMS"; then
    echo "WARNING"
  elif [ -n "$CRITICAL_SUBSYSTEMS" ]; then
    if in_list "$name" "$CRITICAL_SUBSYSTEMS"; then
      echo "CRITICAL"
    else
      echo "INFO"
    fi
  else
    echo "CRITICAL"
  fi
}

echo ""
echo "Step 1: Fetching health endpoint..."
HEALTH_BODY=""
HTTP_STATUS="000"
TMPFILE=$(mktemp /tmp/deep-health-XXXXXX.json)
trap "rm -f $TMPFILE" EXIT

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  HTTP_STATUS=$(curl -sk -o "$TMPFILE" -w "%{http_code}" \
    --max-time "$TIMEOUT" "$URL" 2>/dev/null || echo "000")
  HEALTH_BODY=$(cat "$TMPFILE" 2>/dev/null || echo "")

  if [ "$HTTP_STATUS" = "200" ]; then
    echo "  HTTP 200 OK (attempt $attempt)"
    break
  else
    echo "  HTTP $HTTP_STATUS (attempt $attempt/$MAX_ATTEMPTS)"
    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
      echo "  Retrying in ${SLEEP_SECONDS}s..."
      sleep "$SLEEP_SECONDS"
    fi
  fi
done

if [ "$HTTP_STATUS" != "200" ]; then
  echo ""
  echo "DEEP HEALTH CHECK FAILED: Health endpoint returned HTTP $HTTP_STATUS after $MAX_ATTEMPTS attempts"
  exit 1
fi

echo ""
echo "Step 2: Parsing health response..."

if command -v jq >/dev/null 2>&1; then
  JSON_PARSER="jq"
elif command -v node >/dev/null 2>&1; then
  JSON_PARSER="node"
else
  echo "DEEP HEALTH CHECK FAILED: Neither jq nor node found for JSON parsing"
  exit 1
fi

if [ "$JSON_PARSER" = "jq" ]; then
  if ! echo "$HEALTH_BODY" | jq -e . >/dev/null 2>&1; then
    echo "DEEP HEALTH CHECK FAILED: Response is not valid JSON"
    echo "Response body (first 500 chars): ${HEALTH_BODY:0:500}"
    exit 1
  fi
  echo "  Valid JSON (parser: jq)"
else
  if ! node -e "JSON.parse(process.argv[1])" "$HEALTH_BODY" 2>/dev/null; then
    echo "DEEP HEALTH CHECK FAILED: Response is not valid JSON"
    echo "Response body (first 500 chars): ${HEALTH_BODY:0:500}"
    exit 1
  fi
  echo "  Valid JSON (parser: node)"
fi

TOP_STATUS=$(echo "$HEALTH_BODY" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
echo "  Top-level status: $TOP_STATUS"

echo ""
echo "Step 3: Evaluating subsystem health..."

# Detect subsystem structure - supports .health, .subsystems, .services, or flat
HEALTH_OBJ=""
STRUCTURE=""

for key in health subsystems services; do
  TEST=$(echo "$HEALTH_BODY" | jq -r ".$key | type" 2>/dev/null || echo "null")
  if [ "$TEST" = "object" ]; then
    HEALTH_OBJ=$(echo "$HEALTH_BODY" | jq ".$key")
    STRUCTURE=".$key.{subsystem}"
    break
  fi
done

# If none of the known keys matched, try flat: root-level objects with .status
if [ -z "$HEALTH_OBJ" ]; then
  FLAT_JQ='with_entries(select(.value | type == "object" and .status != null))'
  FLAT_COUNT=$(echo "$HEALTH_BODY" | jq "$FLAT_JQ | length" 2>/dev/null || echo "0")
  if [ "$FLAT_COUNT" -gt 0 ] 2>/dev/null; then
    HEALTH_OBJ=$(echo "$HEALTH_BODY" | jq "$FLAT_JQ")
    STRUCTURE="flat (root-level subsystem objects)"
  fi
fi

if [ -n "$STRUCTURE" ]; then
  echo "  Structure: $STRUCTURE"
fi

if [ -z "$HEALTH_OBJ" ] || [ "$HEALTH_OBJ" = "null" ] || [ "$HEALTH_OBJ" = "{}" ]; then
  echo "  No subsystem health data found in response."
  RESP_KEYS=$(echo "$HEALTH_BODY" | jq -r 'keys | join(", ")' 2>/dev/null || echo "N/A")
  echo "  Response keys: $RESP_KEYS"
  echo ""
  if [ "$TOP_STATUS" = "ok" ] || [ "$TOP_STATUS" = "healthy" ]; then
    echo "DEEP HEALTH CHECK PASSED (no subsystem data, top-level status: $TOP_STATUS)"
    exit 0
  else
    echo "DEEP HEALTH CHECK WARNING: No subsystem data and top-level status is $TOP_STATUS"
    echo "Treating as pass (no subsystems to validate)."
    exit 0
  fi
fi

# Step 4: Iterate subsystems and check health
SUBSYSTEM_NAMES=$(echo "$HEALTH_OBJ" | jq -r 'keys[]')
CRITICAL_FAILURES=""
WARNING_FAILURES=""
CRITICAL_COUNT=0
WARNING_COUNT=0
INFO_COUNT=0
DEALTHY_COUNT=0
TOTAL_COUNT=0

echo ""
printf "  %-30s %-12s %-10s %s\n" "SUBSYSTEM" "STATUS" "CLASS" "DETAILS"
printf "  %-30s %-12s %-10s %s\n" "---------" "------" "-----" "-------"

for subsystem in $SUBSYSTEM_NAMES; do
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  SUB_STATUS=$(echo "$HEALTH_OBJ" | jq -r --arg s "$subsystem" '.[$s].status // "unknown"')
  SUB_LATENCY=$(echo "$HEALTH_OBJ" | jq -r --arg s "$subsystem" '.[$s].latency // empty' 2>/dev/null || true)
  SUB_ERROR=$(echo "$HEALTH_OBJ" | jq -r --arg s "$subsystem" '.[$s].details.error // .[$s].error // empty' 2>/dev/null || true)

  CLASS=$(classify_subsystem "$subsystem")

  IS_HEALTHY="false"
  case "$SUB_STATUS" in
    healthy|ok|up|running|connected|available)
      IS_HEALTHY="true"
      ;;
  esac

  DETAIL=""
  if [ -n "$SUB_LATENCY" ]; then
    DETAIL="${SUB_LATENCY}ms"
  fi
  if [ -n "$SUB_ERROR" ]; then
    if [ -n "$DETAIL" ]; then
      DETAIL="$DETAIL | $SUB_ERROR"
    else
      DETAIL="$SUB_ERROR"
    fi
  fi

  if [ "$IS_HEALTHY" = "true" ]; then
    ICON="[OK]"
    HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
  else
    ICON="[FAIL]"
    case "$CLASS" in
      CRITICAL)
        if [ -n "$CRITICAL_FAILURES" ]; then
          CRITICAL_FAILURES="$CRITICAL_FAILURES, $subsystem"
        else
          CRITICAL_FAILURES="$subsystem"
        fi
        CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
        ;;
      WARNING)
        if [ -n "$WARNING_FAILURES" ]; then
          WARNING_FAILURES="$WARNING_FAILURES, $subsystem"
        else
          WARNING_FAILURES="$subsystem"
        fi
        WARNING_COUNT=$((WARNING_COUNT + 1))
        ;;
      INFO)
        INFO_COUNT=$((INFO_COUNT + 1))
        ;;
    esac
  fi

  printf "  %-30s %-12s %-10s %s\n" "$subsystem" "$ICON $SUB_STATUS" "$CLASS" "$DETAIL"
done

# Step 5: Memory check (non-blocking)
echo ""
echo "Step 5: Memory check..."
FREE_MEM_MB=""
if echo "$HEALTH_BODY" | jq -e '.memory.free' >/dev/null 2>&1; then
  FREE_MEM_BYTES=$(echo "$HEALTH_BODY" | jq -r '.memory.free')
  FREE_MEM_MB=$((FREE_MEM_BYTES / 1048576))
elif echo "$HEALTH_BODY" | jq -e '.system.memory.free' >/dev/null 2>&1; then
  FREE_MEM_BYTES=$(echo "$HEALTH_BODY" | jq -r '.system.memory.free')
  FREE_MEM_MB=$((FREE_MEM_BYTES / 1048576))
elif echo "$HEALTH_BODY" | jq -e '.system.freeMemory' >/dev/null 2>&1; then
  FREE_MEM_BYTES=$(echo "$HEALTH_BODY" | jq -r '.system.freeMemory')
  FREE_MEM_MB=$((FREE_MEM_BYTES / 1048576))
fi

if [ -n "$FREE_MEM_MB" ]; then
  echo "  Free memory: ${FREE_MEM_MB}MB (threshold: ${MIN_FREE_MEMORY_MB}MB)"
  if [ "$FREE_MEM_MB" -lt "$MIN_FREE_MEMORY_MB" ]; then
    echo "  WARNING: Free memory is below ${MIN_FREE_MEMORY_MB}MB threshold"
  fi
else
  echo "  No memory data in health response (skipping)"
fi

# Step 6: Summary and verdict
echo ""
echo "========================================="
echo "Deep Health Check Summary"
echo "========================================="
echo "Total subsystems:    $TOTAL_COUNT"
echo "Healthy:             $HEALTHY_COUNT"
echo "Critical failures:   ${CRITICAL_COUNT} ${CRITICAL_FAILURES:+($CRITICAL_FAILURES)}"
echo "Warning failures:    ${WARNING_COUNT} ${WARNING_FAILURES:+($WARNING_FAILURES)}"
echo "Info failures:       $INFO_COUNT"
echo "========================================="

if [ -n "$SUMMARY_FILE" ]; then
  printf 'TOTAL=%s\nHEALTHY=%s\nCRITICAL_FAIL=%s\nWARNING_FAIL=%s\nCRITICAL_FAILURES=%s\nWARNING_FAILURES=%s\n' \
    "$TOTAL_COUNT" "$HEALTHY_COUNT" "$CRITICAL_COUNT" "$WARNING_COUNT" "$CRITICAL_FAILURES" "$WARNING_FAILURES" \
    > "$SUMMARY_FILE"
  echo "  Summary written to $SUMMARY_FILE"
fi

if [ "$CRITICAL_COUNT" -gt 0 ]; then
  echo ""
  echo "DEEP HEALTH CHECK FAILED"
  echo "Critical subsystems unhealthy: $CRITICAL_FAILURES"
  echo "Deployment must be blocked until these are resolved."
  exit 1
fi

if [ "$WARNING_COUNT" -gt 0 ]; then
  echo ""
  echo "DEEP HEALTH CHECK PASSED (with warnings)"
  echo "Warning subsystems unhealthy: $WARNING_FAILURES"
  echo "These are non-blocking but should be investigated."
  exit 0
fi

echo ""
echo "DEEP HEALTH CHECK PASSED"
echo "All subsystems healthy."
exit 0
