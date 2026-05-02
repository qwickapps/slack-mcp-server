# P3 Multiplexer Design

**Phase:** 3 of the qwickapps/slack-mcp-server fork pivot
**Prereqs landed:** P1 (Dockerfile + pipeline), P2 (token-bridge + DB schema)
**Status:** Design only — no code yet

---

## Overview

The multiplexer is a single HTTP service (`cmd/multiplexer/`) that presents one MCP endpoint to the aggregator (qwickapps/mcp) and, behind the scenes, routes each request to the correct per-team `mcp-server` child process. Each child is a stock upstream binary launched with the decrypted xoxc/xoxd for its team.

---

## Topology / Request Flow

```
qwickapps/mcp plugin (P6)
  │  HTTP POST /teams/{team_id}/mcp  (or header variant — see Routing)
  │  Authorization: Bearer <MULTIPLEXER_SERVICE_KEY>
  ▼
cmd/multiplexer  (port 13082, Tailscale-only)
  │  looks up registry[team_id]
  │  if child not running → decrypt tokens → os.StartProcess with env
  │  pipes MCP frames via stdin/stdout (stdio transport)
  ▼
cmd/slack-mcp-server  (--transport stdio, one per team_id)
  │  reads SLACK_MCP_XOXC_TOKEN + SLACK_MCP_XOXD_TOKEN from env
  ▼
api.slack.com
```

Response path is the reverse. The multiplexer is a transparent MCP frame relay; it does not parse MCP payloads.

---

## Affected Files

`cmd/multiplexer/main.go` — new; entry point, config load, HTTP server, shutdown
`cmd/multiplexer/config.go` — new; `loadConfig()` mirroring token-bridge pattern
`pkg/multiplexer/registry.go` — new; per-team child state, mutex, spawn/teardown
`pkg/multiplexer/reader.go` — new; DB read-through for workspaces, refresh detection
`pkg/multiplexer/proxy.go` — new; HTTP handler, MCP frame relay via stdio
`pkg/multiplexer/health.go` — new; `/_health` and `/_status` handlers
`Dockerfile.qwickapps` — additive: second `go build` line for multiplexer binary
`migrations/` — no changes; schema is already sufficient

`pkg/tokenbridge/store.go` — NOT modified; only the `Ping` method is reused via the `WorkspaceStore` interface. The multiplexer defines its own narrower read-only interface (see below).

---

## API Design

### External HTTP endpoints (port 13082)

```
POST /teams/{team_id}/mcp
  Request body:  raw MCP JSON-RPC frame (any content-type; passed through opaquely)
  Response body: raw MCP JSON-RPC response frame
  Status:        200 on success; 401 missing/bad key; 404 unknown team; 503 child dead
  Auth:          Authorization: Bearer <MULTIPLEXER_SERVICE_KEY>

GET  /_health
  Response: {"status":"ok"} 200  |  {"status":"unhealthy"} 503
  Checks: DB ping

GET  /_status  (admin; same auth as above)
  Response: {"teams": [{"team_id": "...", "state": "running|starting|idle|error", "pid": 1234}]}
```

### Internal Go interfaces

```go
// WorkspaceReader is the subset of DB access the multiplexer needs.
// Implemented by pkg/multiplexer.DBReader (wraps *sql.DB directly, no
// dependency on pkg/tokenbridge.Store which also owns write paths).
type WorkspaceReader interface {
    ListWorkspaces(ctx context.Context) ([]Workspace, error)
    GetWorkspace(ctx context.Context, teamID string) (Workspace, error)
    Ping(ctx context.Context) error
}

type Workspace struct {
    TeamID          string
    TeamName        string
    XoxcEnc         []byte
    XoxdEnc         []byte
    LastRefreshedAt time.Time
}
```

`tokenbridge.Cipher.Decrypt` is used as-is; the multiplexer imports `pkg/tokenbridge` for this single function.

### Registry entry (internal, `pkg/multiplexer/registry.go`)

```go
type childState int
const (
    stateStarting childState = iota
    stateRunning
    stateIdle
    stateCrashed
)

type entry struct {
    teamID          string
    cmd             *exec.Cmd
    stdin           io.WriteCloser
    stdout          io.ReadCloser
    state           childState
    lastUsed        time.Time
    lastRefreshedAt time.Time  // matches workspaces.last_refreshed_at at spawn time
    mu              sync.Mutex // guards state + cmd fields for this entry only
}

type Registry struct {
    mu      sync.RWMutex
    entries map[string]*entry  // keyed by team_id
    // ...config fields
}
```

Two-level locking: `Registry.mu` is a read-write lock taken briefly to look up or insert an entry; `entry.mu` is held for the duration of a spawn or teardown. This lets concurrent requests for different teams proceed without serialising on the top-level lock.

---

## Routing Strategy

**Chosen: URL path prefix `/teams/{team_id}/mcp`**

The aggregator plugin (P6) already passes a `workspace` parameter on every tool. The plugin will extract the team_id and include it in the URL before forwarding the MCP frame. This keeps the multiplexer stateless with respect to session routing — no sticky sessions, no magic headers.

Alternative considered: `X-Slack-Team-ID` header. Rejected because URL path is visible in access logs, easier to proxy-route at the CapRover level if needed, and consistent with REST conventions.

Alternative considered: embed team_id inside the MCP frame itself (tool argument injection). Rejected: requires parsing MCP payloads, creates a protocol coupling with upstream, and breaks if upstream adds new tool shapes.

---

## Child Lifecycle

### State machine

```
(not present)
    │  first request for team_id
    ▼
STARTING  ← spawn process, set up stdio pipes, set state
    │  process ready (check: write initialize request, read response, timeout 5s)
    ▼
RUNNING   ← serve requests; update lastUsed on each request
    │  idle timeout (configurable, default 10 min; checked by background sweeper)
    ▼
IDLE      ← send SIGTERM; wait 2s; SIGKILL; remove entry
    │  or:
    │  process exits unexpectedly
    ▼
CRASHED   ← log; entry kept with crashedAt; retry after backoff (30s, 60s, 120s, cap 300s)

    │  token-bridge writes new last_refreshed_at (detected by poller)
    │  applies to RUNNING or IDLE state
    ▼
STARTING  ← gracefully replace: SIGTERM existing child, re-spawn with fresh tokens
```

### Spawn details

- `exec.Cmd` with `Path = /usr/local/bin/mcp-server` and `Args = ["mcp-server", "--transport", "stdio"]`
- Env vars passed explicitly: `SLACK_MCP_XOXC_TOKEN`, `SLACK_MCP_XOXD_TOKEN` (decrypted), plus forwarded subset from host env: `SLACK_MCP_ENABLED_TOOLS`, `SLACK_MCP_ADD_MESSAGE_TOOL`
- `cmd.Stdin` and `cmd.Stdout` are pipe pairs owned by the entry
- `cmd.Stderr` redirected to a `log.Writer` prefixed with `[mux team=<team_id>]`
- Context passed to `cmd.Start` is the multiplexer's root context; process teardown uses `cmd.Process.Signal` + wait, not context cancellation, so a child crash does not cancel in-flight requests

### Idle sweep

A background goroutine (ticker, interval = `idleTimeout / 2`) scans all entries, terminates children with `lastUsed` older than `idleTimeout`, transitions them to removed state. Default `idleTimeout` = 10 minutes, configurable via env `MULTIPLEXER_IDLE_TIMEOUT`.

### Token refresh detection

A background goroutine polls `workspaces` every `refreshPollInterval` (default 30s, configurable). If `last_refreshed_at` for a team has advanced beyond the child's `lastRefreshedAt`, the multiplexer:
1. Acquires the entry mutex
2. SIGTERMs the running child (2s grace), then SIGKILLs if needed
3. Re-fetches and decrypts tokens
4. Spawns a new child; transitions back to STARTING

In-flight requests during this replacement receive a 503; callers (P6 plugin) should retry with backoff.

---

## DB Read Pattern

The multiplexer has its own `DBReader` (not `tokenbridge.Store`) with two methods:

- `ListWorkspaces` — called at startup and by the refresh poller. Returns all rows ordered by `team_id`.
- `GetWorkspace` — called on first request for a team that is not in the in-memory registry.

No write paths. The multiplexer never calls `UpsertWorkspace` or `WriteAudit`.

**Cache strategy:** the in-memory registry IS the cache. DB is queried only at:
1. Startup (populate registry for all known teams in pre-spawn mode; or no-op in lazy mode)
2. First request for an unknown team_id (GetWorkspace)
3. Every 30s by the refresh poller (ListWorkspaces)

No additional caching layer needed for v1.

---

## Transport Choice

**Chosen: stdio for multiplexer-to-child transport.**

Rationale:
- Zero port allocation complexity. Spawning 10 teams does not require tracking 10 ephemeral ports.
- `exec.Cmd` pipe setup is 5 lines of stdlib. No network stack, TLS, or retry logic for the internal hop.
- MCP frames are newline-delimited JSON; copying between pipes is a `io.Copy` pair in goroutines.
- The multiplexer is the sole writer to the child's stdin — no multiplexing within a single child connection is needed because the registry guarantees one child per team and the handler serialises concurrent requests for the same child via the entry mutex.

HTTP-to-child was considered for observability (could inspect frames at the HTTP level). Rejected: adds port management, an HTTP client, and retry logic for the internal hop without meaningful benefit since the external transport is already HTTP.

---

## External Transport

The multiplexer speaks **HTTP/1.1** on port 13082, unencrypted (Tailscale provides the transport layer). The aggregator plugin in P6 connects via `http.Client` to `http://<multiplexer-host>:13082/teams/{team_id}/mcp`.

SSE is not used externally. The MCP JSON-RPC exchange is request-response; a single HTTP round-trip per MCP call suffices. If upstream ever needs streaming (e.g., for list_channels with pagination callbacks), the design can be extended to chunked transfer encoding — no architectural change required.

---

## Auth

**Shared bearer token: `MULTIPLEXER_SERVICE_KEY` env var.**

The aggregator plugin sends `Authorization: Bearer <key>`. The multiplexer compares with `subtle.ConstantTimeCompare`. No per-team secrets; the service key is a deployment secret managed in the QwickApps secrets store.

This is consistent with the pattern used across other internal qwickapps services (billing-api, projects-api). The endpoint is Tailscale-only so the attack surface is limited to machines on the tailnet.

HMAC-per-request (like token-bridge uses) was considered but adds complexity without meaningful security gain given Tailscale isolation.

---

## Observability

### Endpoints
- `GET /_health` — DB ping, returns 200 `{"status":"ok"}` or 503. Same pattern as token-bridge.
- `GET /_status` — admin; returns per-team child state + pid.

### Log format
Stdlib `log` (matches token-bridge). Each line is prefixed with `multiplexer: ` or `multiplexer team=<team_id>: ` for child-specific events. Key events to log:
- Child spawn: `multiplexer: spawning child team=T1234 pid=<pid>`
- Child exit: `multiplexer: child exited team=T1234 pid=<pid> err=<err>`
- Token refresh trigger: `multiplexer: token refresh detected team=T1234, recycling child`
- Idle teardown: `multiplexer: idle teardown team=T1234`
- Crash backoff: `multiplexer: child crashed team=T1234, retry in <backoff>`
- Rejected auth: `multiplexer: unauthorized team=T1234 ip=<ip>`

---

## Failure Modes

| Scenario | Behavior |
|---|---|
| Token missing for team_id | `GetWorkspace` returns `sql.ErrNoRows`; handler returns 404 `{"error":"unknown team"}` |
| Child crashes repeatedly | After 3 crashes within 5 minutes, entry transitions to CRASHED-BACKOFF. Requests return 503 until backoff clears. Logged at each crash. |
| DB down at startup | `run()` returns error; process exits. CapRover restarts. |
| DB down during request | `GetWorkspace` fails; handler returns 503. In-registry children already running are unaffected (no DB needed for an already-spawned child). |
| Two concurrent first-requests for same team | Registry insert is protected by `Registry.mu` write-lock. Second goroutine blocks on lock, finds entry already in STARTING state, waits (with timeout) for it to reach RUNNING before proceeding. No double-spawn. |
| Token refresh mid-request | Ongoing request holds the entry mutex on the old child. Refresh poller detects the change but waits for the mutex before tearing down. Old request completes; then child is recycled. |
| SIGTERM to multiplexer | Graceful shutdown: stop accepting new requests; send SIGTERM to all running children; wait up to 10s; SIGKILL stragglers; exit. |

---

## Implementation Steps

1. **data layer** — `pkg/multiplexer/reader.go`: `DBReader` implementing `WorkspaceReader`. Reuse same `*sql.DB` wiring as token-bridge. No migrations needed.

2. **registry** — `pkg/multiplexer/registry.go`: `Registry` struct, `entry` struct, `GetOrSpawn(teamID)` (returns `*entry` ready to receive frames), idle sweeper goroutine, crash backoff logic.

3. **proxy handler** — `pkg/multiplexer/proxy.go`: HTTP handler for `POST /teams/{team_id}/mcp`. Reads request body, acquires entry, writes to child stdin, reads child stdout response, writes HTTP response. Timeouts configurable.

4. **health/status handlers** — `pkg/multiplexer/health.go`: `HealthHandler` (DB ping only), `StatusHandler` (registry snapshot).

5. **refresh poller** — `pkg/multiplexer/reader.go` or separate `poller.go`: goroutine that polls `workspaces` every 30s and notifies registry of changed `last_refreshed_at`.

6. **entry point** — `cmd/multiplexer/main.go` + `config.go`: wire everything, HTTP server lifecycle, graceful shutdown. Pattern mirrors `cmd/token-bridge/main.go`.

7. **Dockerfile update** — add `go build ./cmd/multiplexer` line to builder stage; add `COPY --from=builder /out/multiplexer` to final stage.

8. **config env vars** —
   ```
   DATABASE_URL              (shared with token-bridge)
   TOKEN_ENCRYPTION_KEY      (shared with token-bridge)
   MULTIPLEXER_SERVICE_KEY   (new)
   MULTIPLEXER_PORT          default 13082
   MULTIPLEXER_HOST          default 0.0.0.0
   MULTIPLEXER_IDLE_TIMEOUT  default 10m
   MULTIPLEXER_POLL_INTERVAL default 30s
   MCP_SERVER_BIN            default /usr/local/bin/mcp-server
   ```

Each step is independently committable. Steps 1-2 have no HTTP dependency; step 3 depends on step 2; steps 4-5 are parallel; step 6 depends on all prior steps.

---

## Decisions and Rationale

**No pre-spawn at startup.** Lazy-spawn on first request is simpler and avoids holding DB connections open for teams that may not be active. Pre-spawn can be added in P4 if latency on first request is a problem.

**Single child per team, serial request dispatch.** The upstream `mcp-server` binary is single-tenant and its internal state (channel/user caches) is not safe for concurrent callers. Entry-level mutex serialises calls. If throughput becomes a concern, a pool of N children per team is the natural extension but is not warranted for v1.

**No MCP frame parsing in the multiplexer.** The multiplexer copies bytes opaquely. If upstream ever changes its wire format, the multiplexer is unaffected. The only protocol assumption is newline-terminated frames (valid for all three upstream transport modes).

**`pkg/multiplexer` does not import `pkg/tokenbridge.Store`.** Store owns both read and write paths and includes audit logic not needed here. A thin `DBReader` avoids pulling in that surface and makes the read contract explicit.

---

## Open Questions

1. **Startup spawn mode.** Should the multiplexer pre-spawn children for all teams in the DB at startup (guarantees sub-second response for the first request), or lazy-spawn on first request (simpler, avoids idle children for inactive teams)? Design assumes lazy; Raaj should confirm.

2. **Request serialisation granularity.** The current design serialises all concurrent MCP requests for a given team through the single child (entry mutex). If the aggregator is expected to issue parallel Slack tool calls for the same team (e.g., two channels fetched concurrently), this will queue them. Acceptable for v1, or should we design a child-pool (N workers per team) from the start?

3. **Tool name mapping vs. pass-through.** The existing `qwickapps/mcp` Slack plugin has its own tool names (e.g., `slack_send_message`). Upstream `mcp-server` has its own names (`mcp_slack_post_message`). P6 presumably rewrites the plugin. Does P3 need to handle any name translation, or is P6 responsible for the full rewrite so the multiplexer stays dumb? If P3 must translate, the "no MCP frame parsing" decision above is wrong.
