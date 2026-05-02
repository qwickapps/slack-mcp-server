#!/bin/bash
set -e

# Traffic Light Deployment Script
# Implements zero-downtime blue-green deployment with instant rollback capability
#
# Usage:
#   ./deploy-traffic-light.sh \
#     --product <name> \
#     --environment <dev|uat|prod> \
#     --image-ref <ref> \
#     --caprover-url <url> \
#     --caprover-password <password> \
#     --github-token <token> \
#     --github-owner <owner> \
#     [--route-caprover-url <url>] \
#     [--route-caprover-password <password>] \
#     [--health-path <path>] \
#     [--run-migrations <true|false>] \
#     [--run-e2e <true|false>] \
#     [--db-branch-name <branch>]
#     [--critical-subsystems <list>]      # comma-separated; MUST be healthy or deploy blocks
#     [--required-healthy <list>]         # alias for --critical-subsystems
#     [--warning-subsystems <list>]       # comma-separated; unhealthy logs a warning, does not block
#     [--prod-critical-subsystems <list>] # warning in dev, promoted to critical in uat/prod

PRODUCT=""
ENVIRONMENT=""
IMAGE_REF=""
CAPROVER_URL=""
CAPROVER_PASSWORD=""
GITHUB_TOKEN=""
GITHUB_OWNER="qwickapps"
ROUTE_CAPROVER_URL=""
ROUTE_CAPROVER_PASSWORD=""
HEALTH_PATH="/api/health"
RUN_MIGRATIONS="true"
RUN_E2E="true"
DB_BRANCH_NAME=""
CRITICAL_SUBSYSTEMS=""
WARNING_SUBSYSTEMS=""
PROD_CRITICAL_SUBSYSTEMS=""

# SCRIPT_DIR_OVERRIDE: allows tests to redirect sibling-script resolution
# to a mock directory without modifying this file. See issue #20 / test-deploy-traffic-light.sh.
SCRIPT_DIR="${SCRIPT_DIR_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DEPLOY_SCRIPT="$SCRIPT_DIR/deploy-from-ghcr.sh"
CONFIGURE_SCRIPT="$SCRIPT_DIR/configure-caprover-app.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-deployment-health.sh"
DEEP_HEALTH_SCRIPT="$SCRIPT_DIR/deep-health-check.sh"

while [[ $# -gt 0 ]]; do
  case $1 in
    --product)
      PRODUCT="$2"
      shift 2
      ;;
    --environment)
      ENVIRONMENT="$2"
      shift 2
      ;;
    --image-ref)
      IMAGE_REF="$2"
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
    --github-token)
      GITHUB_TOKEN="$2"
      shift 2
      ;;
    --github-owner)
      GITHUB_OWNER="$2"
      shift 2
      ;;
    --route-caprover-url)
      ROUTE_CAPROVER_URL="$2"
      shift 2
      ;;
    --route-caprover-password)
      ROUTE_CAPROVER_PASSWORD="$2"
      shift 2
      ;;
    --health-path)
      HEALTH_PATH="$2"
      shift 2
      ;;
    --run-migrations)
      RUN_MIGRATIONS="$2"
      shift 2
      ;;
    --run-e2e)
      RUN_E2E="$2"
      shift 2
      ;;
    --db-branch-name)
      DB_BRANCH_NAME="$2"
      shift 2
      ;;
    --critical-subsystems|--required-healthy)
      CRITICAL_SUBSYSTEMS="$2"
      shift 2
      ;;
    --warning-subsystems)
      WARNING_SUBSYSTEMS="$2"
      shift 2
      ;;
    --prod-critical-subsystems)
      PROD_CRITICAL_SUBSYSTEMS="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [ -z "$PRODUCT" ] || [ -z "$ENVIRONMENT" ] || [ -z "$IMAGE_REF" ]; then
  echo "Error: Missing required arguments"
  echo "Usage: $0 \\"
  echo "  --product <name> \\"
  echo "  --environment <dev|uat|prod> \\"
  echo "  --image-ref <ref> \\"
  echo "  --caprover-url <url> \\"
  echo "  --caprover-password <password> \\"
  echo "  --github-token <token> \\"
  echo "  [--health-path <path>] \\"
  echo "  [--run-migrations <true|false>] \\"
  echo "  [--run-e2e <true|false>] \\"
  echo "  [--db-branch-name <branch>] \\"
  echo "  [--critical-subsystems|--required-healthy <comma-separated-list>] \\"
  echo "  [--warning-subsystems <comma-separated-list>] \\"
  echo "  [--prod-critical-subsystems <comma-separated-list>]"
  exit 1
fi

case $ENVIRONMENT in
  dev)
    # dev: single-slot environment — build IS the live slot.
    # See https://github.com/qwickapps/slack/issues/20
    APP_BUILD="${PRODUCT}"
    APP_LIVE="${PRODUCT}"
    APP_STABLE=""
    DB_BRANCH="${DB_BRANCH_NAME:-${PRODUCT}-build}"
    ;;
  uat)
    APP_BUILD="${PRODUCT}-uat-build"
    APP_LIVE="${PRODUCT}-uat"
    APP_STABLE="${PRODUCT}-uat-stable"
    DB_BRANCH="${DB_BRANCH_NAME:-${PRODUCT}-uat-build}"
    ;;
  prod)
    APP_BUILD="${PRODUCT}-build"
    APP_LIVE="${PRODUCT}-live"
    APP_STABLE="${PRODUCT}-stable"
    DB_BRANCH="${DB_BRANCH_NAME:-${PRODUCT}-build}"
    ;;
  *)
    echo "Error: Invalid environment '$ENVIRONMENT'. Must be dev, uat, or prod"
    exit 1
    ;;
esac

# Dev: single-slot — no swap, no stable, no live-slot verify.
# Build IS the live slot. All health checks already ran in deploy-and-verify.
# See: https://github.com/qwickapps/slack/issues/20
if [ "$ENVIRONMENT" = "dev" ]; then
  echo "INFO: dev environment — single-slot, skipping swap and live-verify steps."
  echo "Traffic Light Deployment Complete (dev, no-swap)"
  echo "  Slot: $APP_BUILD already serving traffic"
  exit 0
fi

echo "========================================="
echo "Traffic Light Deployment"
echo "========================================="
echo "Product: $PRODUCT"
echo "Environment: $ENVIRONMENT"
echo "Image: $IMAGE_REF"
echo "Build App: $APP_BUILD"
echo "Live App: $APP_LIVE"
echo "Stable App: $APP_STABLE"
echo "DB Branch: $DB_BRANCH"
echo "Health Path: $HEALTH_PATH"
echo "Run Migrations: $RUN_MIGRATIONS"
echo "Run E2E: $RUN_E2E"
echo "Critical subsystems: ${CRITICAL_SUBSYSTEMS:-all}"
echo "Warning subsystems: ${WARNING_SUBSYSTEMS:-none}"
echo "Prod-critical subsystems: ${PROD_CRITICAL_SUBSYSTEMS:-none}"
echo "========================================="

# ── Resolve effective subsystem classification ──────────────────────────────
# prod_critical_subsystems are warnings in dev but must be healthy in uat/prod.
if [ -n "$PROD_CRITICAL_SUBSYSTEMS" ]; then
  if [ "$ENVIRONMENT" != "dev" ]; then
    # Promote to CRITICAL for uat/prod
    if [ -n "$CRITICAL_SUBSYSTEMS" ]; then
      CRITICAL_SUBSYSTEMS="${CRITICAL_SUBSYSTEMS},${PROD_CRITICAL_SUBSYSTEMS}"
    else
      CRITICAL_SUBSYSTEMS="${PROD_CRITICAL_SUBSYSTEMS}"
    fi
    # Drop from WARNING to avoid duplicate classification
    NEW_WARNING=""
    IFS=',' read -ra WARN_ITEMS <<< "$WARNING_SUBSYSTEMS"
    for item in "${WARN_ITEMS[@]}"; do
      item=$(echo "$item" | xargs)
      found=0
      IFS=',' read -ra PCRIT_ITEMS <<< "$PROD_CRITICAL_SUBSYSTEMS"
      for pc in "${PCRIT_ITEMS[@]}"; do
        pc=$(echo "$pc" | xargs)
        [ "$item" = "$pc" ] && found=1 && break
      done
      [ $found -eq 0 ] && [ -n "$item" ] && NEW_WARNING="${NEW_WARNING:+$NEW_WARNING,}$item"
    done
    WARNING_SUBSYSTEMS="$NEW_WARNING"
    echo "ENV=$ENVIRONMENT: promoted prod_critical_subsystems ($PROD_CRITICAL_SUBSYSTEMS) to CRITICAL"
  else
    # dev: treat as warnings (non-blocking)
    if [ -n "$WARNING_SUBSYSTEMS" ]; then
      WARNING_SUBSYSTEMS="${WARNING_SUBSYSTEMS},${PROD_CRITICAL_SUBSYSTEMS}"
    else
      WARNING_SUBSYSTEMS="${PROD_CRITICAL_SUBSYSTEMS}"
    fi
    echo "ENV=dev: treating prod_critical_subsystems ($PROD_CRITICAL_SUBSYSTEMS) as WARNING (non-blocking)"
  fi
fi


echo ""
echo "=== Step 1: Deploy to Build (Red) ==="

if [ -f "$DEPLOY_SCRIPT" ]; then
  "$DEPLOY_SCRIPT" \
    --app-name "$APP_BUILD" \
    --image-ref "$IMAGE_REF" \
    --caprover-url "$CAPROVER_URL" \
    --caprover-password "$CAPROVER_PASSWORD" \
    --github-token "$GITHUB_TOKEN" \
    --github-owner "$GITHUB_OWNER"
else
  echo "Error: deploy-from-ghcr.sh not found at $DEPLOY_SCRIPT"
  exit 1
fi

echo ""
echo "=== Step 2: Wait for deployment to stabilize ==="
echo "Waiting 60s for CapRover deployment to stabilize..."
sleep 60

if [ -n "$VALIDATE_SCRIPT" ] && [ -f "$VALIDATE_SCRIPT" ]; then
  BUILD_URL="https://${APP_BUILD}.app.qwickforge.com"
  if [ "$ENVIRONMENT" = "dev" ]; then
    BUILD_URL="https://${APP_BUILD}.dev.qwickforge.com"
  fi

  echo ""
  echo "=== Validating Build Instance Health ==="
  "$VALIDATE_SCRIPT" \
    --app-name "$APP_BUILD" \
    --caprover-url "$CAPROVER_URL" \
    --caprover-password "$CAPROVER_PASSWORD" \
    --app-url "$BUILD_URL" \
    --health-path "$HEALTH_PATH" \
    --max-attempts 15 \
    --sleep 20 || {
      echo "WARNING: Health check failed for build instance. Traffic remains on live."
      echo "Investigate build issues before retrying."
      exit 1
    }
fi


# Deep health check: validate individual subsystem health (not just HTTP 200)
if [ -f "$DEEP_HEALTH_SCRIPT" ]; then
  echo ""
  echo "=== Deep Health Check (Build Instance) ==="
  DEEP_ARGS=(
    --url "${BUILD_URL}${HEALTH_PATH}"
    --timeout 15
    --max-attempts 3
    --sleep 10
  )
  if [ -n "$CRITICAL_SUBSYSTEMS" ]; then
    DEEP_ARGS+=(--critical-subsystems "$CRITICAL_SUBSYSTEMS")
  fi
  if [ -n "$WARNING_SUBSYSTEMS" ]; then
    DEEP_ARGS+=(--warning-subsystems "$WARNING_SUBSYSTEMS")
  fi
  "$DEEP_HEALTH_SCRIPT" "${DEEP_ARGS[@]}" || {
    echo "CRITICAL: Subsystem health check failed for build instance."
    echo "Traffic remains on live. Deployment blocked."
    exit 1
  }
fi

if [ "$RUN_MIGRATIONS" = "true" ]; then
  echo ""
  echo "=== Step 3: Run Database Migrations ==="
  echo "Migrations would run on branch: $DB_BRANCH"
  echo "(Migration execution requires Neon CLI integration)"
  echo "For now, skipping automatic migrations on build branch"
fi

if [ "$RUN_E2E" = "true" ]; then
  echo ""
  echo "=== Step 4: Run E2E Validation ==="

  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../.. && pwd)"

  # Standalone repo: playwright config at repo root
  E2E_SCRIPT_DIR=""
  PLAYWRIGHT_CONFIG=""
  if [ -f "$REPO_ROOT/playwright.ci.config.ts" ]; then
    E2E_SCRIPT_DIR="$REPO_ROOT"
    PLAYWRIGHT_CONFIG="playwright.ci.config.ts"
  fi

  if [ -n "$E2E_SCRIPT_DIR" ]; then
    echo "Running E2E smoke tests against: $BUILD_URL"
    echo "  config: $E2E_SCRIPT_DIR/$PLAYWRIGHT_CONFIG"

    cd "$E2E_SCRIPT_DIR"

    export PLAYWRIGHT_BASE_URL="$BUILD_URL"
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

    pnpm playwright test \
      --config="$PLAYWRIGHT_CONFIG" \
      --project=chromium \
      --grep="smoke|home|health" \
      --timeout=60000 \
      --reporter=line \
      tests/e2e/ 2>&1
    E2E_RESULT=$?

    if [ $E2E_RESULT -eq 0 ]; then
      echo "E2E smoke tests passed"
    else
      echo "WARNING: E2E smoke tests failed (exit code: $E2E_RESULT)"
      echo "Continuing with deployment - check test results for details"
    fi
  else
    echo "WARNING: No Playwright config found at $REPO_ROOT/playwright.ci.config.ts"
    echo "Skipping E2E validation"
  fi
fi

echo ""
echo "=== Step 5: Swap Instances (Zero Downtime) ==="
echo "Promoting: $APP_BUILD → $APP_LIVE → $APP_STABLE"

if [ -f "$SCRIPT_DIR/swap-instances.sh" ]; then
  "$SCRIPT_DIR/swap-instances.sh" \
    --product "$PRODUCT" \
    --environment "$ENVIRONMENT" \
    --direction promote \
    --caprover-url "$CAPROVER_URL" \
    --caprover-password "$CAPROVER_PASSWORD" \
    --github-token "$GITHUB_TOKEN" \
    --github-owner "$GITHUB_OWNER" \
    --build-image-ref "$IMAGE_REF"
else
  echo "Error: swap-instances.sh not found"
  echo "Manual swap required:"
  echo "  1. Delete $APP_STABLE (if exists)"
  echo "  2. Rename $APP_LIVE → $APP_STABLE"
  echo "  3. Rename $APP_BUILD → $APP_LIVE"
  echo "  4. Update gateway to point to $APP_LIVE"
  exit 1
fi

echo ""
echo "=== Step 6: Update Gateway Routing ==="

case $ENVIRONMENT in
  dev)
    GATEWAY_APP="${PRODUCT}-dev"
    ;;
  uat)
    GATEWAY_APP="${PRODUCT}-uat"
    ;;
  prod)
    GATEWAY_APP="${PRODUCT}"
    ;;
esac

TARGET_APP_URL="https://${APP_LIVE}.app.qwickforge.com"
if [ "$ENVIRONMENT" = "dev" ]; then
  TARGET_APP_URL="https://${APP_LIVE}.dev.qwickforge.com"
fi

if [ -f "$SCRIPT_DIR/setup-qwickway-route.sh" ]; then
  EFFECTIVE_ROUTE_URL="${ROUTE_CAPROVER_URL:-$CAPROVER_URL}"
  EFFECTIVE_ROUTE_PASS="${ROUTE_CAPROVER_PASSWORD:-$CAPROVER_PASSWORD}"
  echo "Updating gateway route: $GATEWAY_APP → $TARGET_APP_URL"
  "$SCRIPT_DIR/setup-qwickway-route.sh" \
    --gateway-app-name "$GATEWAY_APP" \
    --target-app-url "$TARGET_APP_URL" \
    --route-caprover-url "$EFFECTIVE_ROUTE_URL" \
    --route-caprover-password "$EFFECTIVE_ROUTE_PASS" \
    --health-check-path "$HEALTH_PATH" \
    --github-token "$GITHUB_TOKEN" \
    --github-owner "$GITHUB_OWNER" || {
      echo "Warning: Gateway route update failed"
    }
else
  echo "Warning: setup-qwickway-route.sh not found, skipping gateway update"
fi

echo ""
echo "=== Step 7: Verify Live Instance ==="

sleep 30

LIVE_URL="https://${APP_LIVE}.app.qwickforge.com"
if [ "$ENVIRONMENT" = "dev" ]; then
  LIVE_URL="https://${APP_LIVE}.dev.qwickforge.com"
fi

if [ -n "$VALIDATE_SCRIPT" ] && [ -f "$VALIDATE_SCRIPT" ]; then
  "$VALIDATE_SCRIPT" \
    --app-name "$APP_LIVE" \
    --caprover-url "$CAPROVER_URL" \
    --caprover-password "$CAPROVER_PASSWORD" \
    --app-url "$LIVE_URL" \
    --health-path "$HEALTH_PATH" \
    --max-attempts 15 \
    --sleep 20 || {
      echo "WARNING: Live instance health check failed!"
      echo "Consider running rollback:"
      echo "  $0 --product $PRODUCT --environment $ENVIRONMENT --direction rollback ..."
      exit 1
    }
fi

echo ""
echo "========================================="

# Deep health check on live instance
if [ -f "$DEEP_HEALTH_SCRIPT" ]; then
  echo ""
  echo "=== Deep Health Check (Live Instance) ==="
  DEEP_ARGS=(
    --url "${LIVE_URL}${HEALTH_PATH}"
    --timeout 15
    --max-attempts 3
    --sleep 10
  )
  if [ -n "$CRITICAL_SUBSYSTEMS" ]; then
    DEEP_ARGS+=(--critical-subsystems "$CRITICAL_SUBSYSTEMS")
  fi
  if [ -n "$WARNING_SUBSYSTEMS" ]; then
    DEEP_ARGS+=(--warning-subsystems "$WARNING_SUBSYSTEMS")
  fi
  "$DEEP_HEALTH_SCRIPT" "${DEEP_ARGS[@]}" || {
    echo "WARNING: Live instance deep health check failed!"
    echo "Consider running rollback."
    exit 1
  }
fi

echo "Traffic Light Deployment Complete"
echo "========================================="
echo "Build: $APP_BUILD → deployed with $IMAGE_REF"
echo "Live: $APP_LIVE → now serving traffic"
echo "Stable: $APP_STABLE → previous live (rollback ready)"
echo "========================================="
