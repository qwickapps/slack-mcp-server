# Pipeline Workflows — slack-mcp-server

## Pipeline Stages

### Build-slot deployment (push to `master` branch or `workflow_dispatch`)

```
push to master
  └── deploy.yml
        ├── resolve-env        (derive ENV / PUBLIC_URL / CAPROVER_HOST)
        ├── write-env-file     (write /tmp/app-env-slack-mcp-server.env)
        ├── db-wipe            (dev only: skeleton for P3 — skips at P1/P2)
        ├── db-clone           (uat only: skeleton for P3 — skips at P1/P2)
        └── deploy             (calls deploy-app.yml)
              ├── prepare      (image tag, slot names, URLs)
              ├── build        (Docker build + push to GHCR)
              ├── provision-app
              ├── provision-gateway
              ├── deploy-and-verify
              └── cleanup-dev
```

The deploy workflows stop after the build slot is deployed and verified.
They do not promote build to live. Promotion requires an explicit
`workflow_dispatch` run of `promote-to-live.yml`.

### Manual promotion

After `deploy.yml` or `deploy-three-apps.yml` completes, run the promote
workflows in order when an operator wants to advance a specific app manually:

```
promote-to-live.yml   (app_name + image_ref + environment)
  └── validates image_ref format
  └── promotes <app>-build to <app>-live (dev/prod) or <app>-uat (uat)
  └── health checks /sse for slack-mcp-server, /_health for the three P3 apps
  └── Telegram notification with image_ref to paste into stable step

promote-to-stable.yml (same app_name + image_ref + environment)
  └── tags image as stable-<version>-<short_sha> + stable-latest in GHCR
  └── copies live env vars + CMD override to stable
  └── deploys to <app>-stable (dev/prod) or <app>-uat-stable (uat)
  └── health checks /sse for slack-mcp-server, /_health for the three P3 apps
  └── Telegram notification — stable slot is now rollback target
```

---

## CapRover Slot Model

| Environment | Build slot | Live slot | Stable slot |
|-------------|------------|-----------|-------------|
| dev | `<app>-build` | `<app>-live` | `<app>-stable` |
| uat | `slack-mcp-server-uat-build` | `slack-mcp-server-uat` | `slack-mcp-server-uat-stable` |
| prod | `slack-mcp-server-build` | `slack-mcp-server-live` | `slack-mcp-server-stable` |

The P3 caller deploys `slack-bridge`, `slack-multiplexer`, and `slack-setup`
with the same slot pattern. `deploy-three-apps.yml` builds one shared
`img-slack-mcp-server-<env>` image and passes the immutable digest to each app
deploy; each app selects its binary through the CapRover CMD override.

---

## Port / Health endpoint note

The upstream MCP binary listens on port `13080` by default. Port is controlled
by the `SLACK_MCP_PORT` environment variable — there is NO `--port` CLI flag.
The `SLACK_MCP_HOST` var must be `0.0.0.0` for CapRover to proxy the container.

Health check path: `/sse` (the SSE MCP endpoint — returns 200 when server is up).

---

## DB Connectivity (admin URLs — P3 only)

At P1/P2 there is no database. The `db-wipe` (dev) and `db-clone` (uat) jobs
skip gracefully when `SLACK_MCP_SERVER_<ENV>_DATABASE_ADMIN_URL` secrets are
absent. They are retained as skeletons for P3 (token-bridge will add a DB).

When populated, admin URLs MUST point at the Tailscale-reachable direct host:

| Env       | Host                                           | Port |
|-----------|------------------------------------------------|------|
| DEV       | `qwickapps-db-dev.taile324e7.ts.net`           | 6432 |
| UAT/PROD  | `qwickapps-db-main.taile324e7.ts.net`          | 6432 |

The CapRover-internal `srv-captain--*` addresses are NOT reachable from the
macmini runner. Use direct port `6432` (PgBouncer 6433 does not accept admin ops).

---

## Testing Locally

```bash
# Build and run the container locally (requires Tailscale env vars or TS_AUTHKEY unset)
docker build -f Dockerfile.qwickapps -t slack-mcp-server:local .
docker run \
  -e SLACK_MCP_XOXP_TOKEN=xoxp-... \
  -e SLACK_MCP_PORT=13080 \
  -e SLACK_MCP_HOST=0.0.0.0 \
  -p 13080:13080 \
  slack-mcp-server:local

# Verify the SSE endpoint
curl http://localhost:13080/sse
```

---

## Required GitHub Secrets

Set in `qwickapps/slack-mcp-server` repo settings before first run.
See `.github/SECRETS.md` for full list and format.

### Infrastructure (shared with other apps)
- `OCI_MAIN_CAPROVER_URL`
- `OCI_MAIN_CAPROVER_PASSWORD`
- `OCI_DEV_CAPROVER_URL`
- `OCI_DEV_CAPROVER_PASSWORD`
- `OCI_GATEWAY_CAPROVER_URL`
- `OCI_GATEWAY_CAPROVER_PASSWORD`
- `GHCR_PUSH_TOKEN`
- `GHCR_PULL_TOKEN`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`

### App-specific (per environment: DEV / UAT / PROD)
- `SLACK_MCP_SERVER_<ENV>_XOXP_TOKEN`
- `SLACK_MCP_SERVER_<ENV>_XOXC_TOKEN`
- `SLACK_MCP_SERVER_<ENV>_XOXD_TOKEN`
- `SLACK_MCP_SERVER_<ENV>_TS_AUTHKEY`
- `SLACK_MCP_SERVER_<ENV>_TS_API_KEY`

---

## Rollback Procedure

1. Identify failure: Telegram alert fires, or `/sse` returning non-200.
2. `promote-to-stable.yml` NOT yet run: re-run `promote-to-live.yml` with the
   last known-good `image_ref`.
3. `promote-to-stable.yml` already ran: deploy `stable-<version>-<short_sha>`
   image ref via `promote-to-live.yml` to restore live.
4. Authority: any operator with `workflow_dispatch` permission may trigger rollback.
5. Expected rollback time: ~5 min (image pull + container start + 15 health
   check attempts x 20s worst case).
