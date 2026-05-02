#!/bin/sh
set -e

# QwickApps Canonical Tailscale Entrypoint v1.2
# Used by ALL containerized services. Do not customize per-service.
# Config via env vars only: TS_AUTHKEY, TS_HOSTNAME, APP_NAME, TS_TAGS, TS_API_KEY

SERVICE="${TS_HOSTNAME:-${APP_NAME:-unknown}}"
LOG_PREFIX="[${SERVICE}]"
SOCKET="/tmp/tailscale.sock"
SOCKET_TIMEOUT=20
TS_READY_TIMEOUT=15
DNS_PROBE_TIMEOUT=15

log()  { echo "${LOG_PREFIX} $1"; }
fail() { echo "${LOG_PREFIX} FATAL: $1" >&2; exit 1; }

# --- Tailscale setup (skip if no auth key) ---
if [ -z "$TS_AUTHKEY" ]; then
  log "No TS_AUTHKEY set — skipping Tailscale, starting app directly"
  exec "$@"
fi

log "Starting Tailscale..."

# Start tailscaled (userspace networking, no persistent state needed for ephemeral)
tailscaled \
  --tun=userspace-networking \
  --statedir="/var/lib/tailscale/${SERVICE}" \
  --socket="${SOCKET}" \
  --no-logs-no-support \
  2>/dev/null &

# Wait for socket
log "Waiting for tailscaled socket (${SOCKET_TIMEOUT}s)..."
i=0; while [ $i -lt $SOCKET_TIMEOUT ]; do
  [ -S "${SOCKET}" ] && break
  i=$((i + 1)); sleep 1
done
[ -S "${SOCKET}" ] || fail "tailscaled socket not ready after ${SOCKET_TIMEOUT}s"

# Delete ALL stale devices with this hostname (including -N suffixed duplicates)
# The TS API returns the same hostname for duplicates; the -N suffix is only in the FQDN name field.
# We delete ALL matching devices before registering, then wait for expiry to propagate.
if [ -n "$TS_API_KEY" ]; then
  log "Cleaning stale devices for hostname '${SERVICE}'..."
  AUTH_HEADER="Authorization: Bearer ${TS_API_KEY}"
  STALE=$(curl -sf -H "${AUTH_HEADER}" \
    "https://api.tailscale.com/api/v2/tailnet/-/devices" 2>/dev/null | \
    sed 's/},{/\n/g' | \
    grep -F "\"hostname\":\"${SERVICE}\"" | \
    grep -o '"id":"[0-9]*"' | \
    sed 's/"id":"//;s/"//' || true)
  DELETED=0
  for dev_id in $STALE; do
    curl -sf -X DELETE -H "${AUTH_HEADER}" \
      "https://api.tailscale.com/api/v2/device/${dev_id}" 2>/dev/null || true
    log "Removed stale device ${dev_id}"
    DELETED=$((DELETED + 1))
  done
  # Wait for TS coordination server to process deletions before registering
  if [ "$DELETED" -gt 0 ]; then
    log "Waiting 5s for ${DELETED} device deletion(s) to propagate..."
    sleep 5
  fi
fi

# Connect to tailnet
TAGS="${TS_TAGS:-tag:container}"
log "Connecting as '${SERVICE}' with tags '${TAGS}'..."
tailscale --socket="${SOCKET}" up \
  --authkey="${TS_AUTHKEY}" \
  --accept-dns=true \
  --hostname="${SERVICE}" \
  --advertise-tags="${TAGS}" \
  || fail "tailscale up failed — refusing to start without Tailscale connectivity"

# Wait for Running state
log "Waiting for BackendState=Running (${TS_READY_TIMEOUT}s)..."
i=0; while [ $i -lt $TS_READY_TIMEOUT ]; do
  STATE=$(tailscale --socket="${SOCKET}" status --json 2>/dev/null \
    | grep -o '"BackendState": *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"' || echo "unknown")
  [ "$STATE" = "Running" ] && break
  i=$((i + 1)); sleep 1
done
[ "$STATE" = "Running" ] || fail "Tailscale not Running after ${TS_READY_TIMEOUT}s (state: ${STATE})"

# Verify hostname — Tailscale may assign -1, -2 suffix if old device still exists
ACTUAL_HOST=$(tailscale --socket="${SOCKET}" status --json 2>/dev/null \
  | grep -o '"DNSName": *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"' | sed 's/\.$//')
if [ -n "$ACTUAL_HOST" ] && echo "$ACTUAL_HOST" | grep -qE "\-[0-9]+\."; then
  log "WARN: Got suffixed hostname: ${ACTUAL_HOST} — retrying cleanup..."
  tailscale --socket="${SOCKET}" down 2>/dev/null || true
  sleep 3
  # Delete ALL devices matching this hostname (including the one we just created)
  if [ -n "$TS_API_KEY" ]; then
    ALL_DEVICES=$(curl -sf -H "Authorization: Bearer ${TS_API_KEY}" \
      "https://api.tailscale.com/api/v2/tailnet/-/devices" 2>/dev/null | \
      sed 's/},{/\n/g' | \
      grep -F "\"hostname\":\"${SERVICE}\"" | \
      grep -o '"id":"[0-9]*"' | \
      sed 's/"id":"//;s/"//' || true)
    for dev_id in $ALL_DEVICES; do
      curl -sf -X DELETE -H "Authorization: Bearer ${TS_API_KEY}" \
        "https://api.tailscale.com/api/v2/device/${dev_id}" 2>/dev/null || true
      log "Deleted device ${dev_id}"
    done
    log "Waiting 10s for cleanup to propagate..."
    sleep 10
  fi
  # Retry registration
  tailscale --socket="${SOCKET}" up \
    --authkey="${TS_AUTHKEY}" \
    --accept-dns=true \
    --hostname="${SERVICE}" \
    --advertise-tags="${TAGS}" \
    || fail "tailscale up retry failed"
  log "Retry complete"
fi
log "Tailscale connected"

# Configure system DNS to use Tailscale's MagicDNS resolver (100.100.100.100).
# In userspace-networking mode, tailscaled does NOT modify /etc/resolv.conf, so
# .ts.net names are only resolvable if the host happens to forward to 100.100.100.100.
# Prepending the MagicDNS nameserver guarantees .ts.net resolution in any environment.
TS_DNS="100.100.100.100"
if ! grep -q "nameserver ${TS_DNS}" /etc/resolv.conf 2>/dev/null; then
  log "Prepending nameserver ${TS_DNS} to /etc/resolv.conf"
  cp /etc/resolv.conf /etc/resolv.conf.bak
  printf "nameserver %s\n" "${TS_DNS}" | cat - /etc/resolv.conf.bak > /etc/resolv.conf
fi

# Probe MagicDNS using the container's own FQDN (not a public domain —
# 100.100.100.100 only resolves tailnet names, not the public Internet).
TS_SUFFIX=$(tailscale --socket="${SOCKET}" status --json 2>/dev/null \
  | grep -o '"MagicDNSSuffix": *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"' || echo "")
if [ -n "${TS_SUFFIX}" ]; then
  PROBE_NAME="${SERVICE}.${TS_SUFFIX}"
else
  PROBE_NAME="${SERVICE}.ts.net"
fi
log "Probing MagicDNS for ${PROBE_NAME} (${DNS_PROBE_TIMEOUT}s)..."
i=0; while [ $i -lt $DNS_PROBE_TIMEOUT ]; do
  nslookup "${PROBE_NAME}" "${TS_DNS}" >/dev/null 2>&1 && break
  i=$((i + 1)); sleep 1
done
if nslookup "${PROBE_NAME}" "${TS_DNS}" >/dev/null 2>&1; then
  RESOLVED_IP=$(nslookup "${PROBE_NAME}" "${TS_DNS}" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' || echo "")
  log "MagicDNS ready — ${PROBE_NAME} -> ${RESOLVED_IP}"
else
  log "WARN: MagicDNS not responding after ${DNS_PROBE_TIMEOUT}s — .ts.net resolution may fail"
fi

# Expose the app port via Tailscale serve (required for userspace networking).
# Without this, Tailscale connects but doesn't forward traffic to the app.
# Uses --http to serve plain HTTP on the app port (not HTTPS on 443).
APP_PORT="${PORT:-${APP_PORT:-8080}}"
if [ -n "$APP_PORT" ]; then
  log "Setting up tailscale serve --http=${APP_PORT} → localhost:${APP_PORT}..."
  tailscale --socket="${SOCKET}" serve --bg --http="${APP_PORT}" "http://127.0.0.1:${APP_PORT}" 2>/dev/null || \
    log "WARN: tailscale serve failed — port ${APP_PORT} may not be reachable via Tailscale"
fi

# Hand off to application
log "Starting application..."
exec "$@"
