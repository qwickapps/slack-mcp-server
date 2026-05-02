# GitHub Actions Secrets — qwickapps/slack-mcp-server

All secret names referenced by the workflows. Shared infrastructure secrets (10)
plus per-env secrets. No database at P1/P2 — DB secrets are stubbed for P3 (token-bridge).

Set via:

```bash
gh secret set <NAME> --repo qwickapps/slack-mcp-server --body "<value>"
# or, from a file:
gh secret set <NAME> --repo qwickapps/slack-mcp-server < path/to/value
```

## Shared (10 — same value across all envs)

| Name | Source | Notes |
|---|---|---|
| `OCI_DEV_CAPROVER_URL` | infra MCP | e.g. `https://captain.dev.qwickforge.com` |
| `OCI_DEV_CAPROVER_PASSWORD` | infra MCP | |
| `OCI_MAIN_CAPROVER_URL` | infra MCP | e.g. `https://captain.app.qwickforge.com` |
| `OCI_MAIN_CAPROVER_PASSWORD` | infra MCP | |
| `OCI_GATEWAY_CAPROVER_URL` | infra MCP | gateway CapRover instance |
| `OCI_GATEWAY_CAPROVER_PASSWORD` | infra MCP | |
| `GHCR_PUSH_TOKEN` | infra MCP | PAT with `write:packages` for `qwickapps` |
| `GHCR_PULL_TOKEN` | infra MCP | PAT with `read:packages` |
| `TELEGRAM_BOT_TOKEN` | infra MCP | for promote workflow notifications |
| `TELEGRAM_CHAT_ID` | infra MCP | |

## Per-env (5 each × 3 envs = 15 total at P1/P2)

For each `<ENV>` ∈ `{DEV, UAT, PROD}`:

| Name | Notes |
|---|---|
| `SLACK_MCP_SERVER_<ENV>_XOXP_TOKEN` | Slack user token (xoxp-...). Optional if using xoxc+xoxd. |
| `SLACK_MCP_SERVER_<ENV>_XOXC_TOKEN` | Slack cookie token (xoxc-...). |
| `SLACK_MCP_SERVER_<ENV>_XOXD_TOKEN` | Slack d-cookie. |
| `SLACK_MCP_SERVER_<ENV>_TS_AUTHKEY` | Tailscale ephemeral auth key |
| `SLACK_MCP_SERVER_<ENV>_TS_API_KEY` | Tailscale API key for stale-device cleanup |

### P3 stubs (not needed until token-bridge lands)

For each `<ENV>` ∈ `{DEV, UAT, PROD}`:

| Name | Notes |
|---|---|
| `SLACK_MCP_SERVER_<ENV>_DATABASE_URL` | App DB URL (future: token-bridge) |
| `SLACK_MCP_SERVER_<ENV>_DATABASE_ADMIN_URL` | Admin URL for db-wipe/db-clone jobs. Must use Tailscale-routed direct host (not srv-captain-- internal address). |

## Port note

The MCP server listens on port `13080` (set via `SLACK_MCP_PORT` env var in the
env file written by the deploy workflow). There is no `--port` CLI flag. The
health path is `/sse`.
