#!/usr/bin/env bash
set -euo pipefail

if [ -z "${GITHUB_ENV:-}" ]; then
  echo "GITHUB_ENV is not set"
  exit 1
fi

unset DOCKER_HOST

COLIMA_SOCK="$HOME/.colima/default/docker.sock"
if [ -S "$COLIMA_SOCK" ]; then
  COLIMA_HOST="unix://$COLIMA_SOCK"
  if docker -H "$COLIMA_HOST" info >/dev/null 2>&1; then
    echo "Resolved Docker endpoint via Colima socket: $COLIMA_HOST"
    echo "DOCKER_HOST=$COLIMA_HOST" >> "$GITHUB_ENV"
    # Prefer Colima's own docker CLI (no osxkeychain integration) when available.
    # Docker Desktop's CLI (/usr/local/bin/docker) invokes the keychain helper even
    # when DOCKER_CONFIG is overridden, causing -25308 on headless macOS runners.
    COLIMA_DOCKER="/opt/homebrew/bin/docker"
    if [ -x "$COLIMA_DOCKER" ]; then
      echo "DOCKER_CLI=$COLIMA_DOCKER" >> "$GITHUB_ENV"
      echo "Using Colima docker CLI: $COLIMA_DOCKER"
    else
      echo "DOCKER_CLI=docker" >> "$GITHUB_ENV"
    fi
    exit 0
  fi
fi

for ctx in colima default desktop-linux; do
  if docker context inspect "$ctx" >/dev/null 2>&1 && docker --context "$ctx" info >/dev/null 2>&1; then
    host=$(docker context inspect "$ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
    if [ -n "$host" ]; then
      echo "Resolved Docker endpoint via context '$ctx': $host"
      echo "DOCKER_HOST=$host" >> "$GITHUB_ENV"
      exit 0
    fi
  fi
done

for ctx in $(docker context ls --format '{{.Name}}' 2>/dev/null || true); do
  if docker --context "$ctx" info >/dev/null 2>&1; then
    host=$(docker context inspect "$ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
    if [ -n "$host" ]; then
      echo "Resolved Docker endpoint via context '$ctx': $host"
      echo "DOCKER_HOST=$host" >> "$GITHUB_ENV"
      exit 0
    fi
  fi
done

if docker info >/dev/null 2>&1; then
  echo "Docker endpoint available via default client configuration"
  exit 0
fi

echo "No reachable Docker endpoint found (default, Colima socket, or docker contexts)"
exit 1
