package multiplexer

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

// childState enumerates the lifecycle states of a per-team child process.
type childState int

const (
	stateStarting childState = iota
	stateRunning
	stateIdle    // graceful shutdown in progress
	stateCrashed // process exited unexpectedly; only used in /_status snapshots
)

func (s childState) String() string {
	switch s {
	case stateStarting:
		return "starting"
	case stateRunning:
		return "running"
	case stateIdle:
		return "idle"
	case stateCrashed:
		return "crashed"
	default:
		return "unknown"
	}
}

// entry holds the runtime state for one per-team child process.
// entry.mu serialises all access to the fields below it; Registry.mu
// is only taken to insert or look up entries in the map.
type entry struct {
	teamID string

	mu     sync.Mutex // guards all fields below
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.ReadCloser

	// done is closed by watchChild when the child process has fully exited.
	// Teardown and waitRunning both select on this channel.
	done chan struct{}

	state           childState
	pid             int // 0 when not running
	lastUsed        time.Time
	lastRefreshedAt time.Time // value of workspaces.last_refreshed_at at spawn time
}

// crashRecord tracks backoff state for a crashed team.
// Stored on Registry (not entry) so it survives the entry deletion on crash.
type crashRecord struct {
	count       int
	nextRetryAt time.Time
}

// ErrCrashBackoff is returned by GetOrSpawn when the team's child has crashed
// and the backoff window has not yet elapsed. Callers should return 503.
var ErrCrashBackoff = fmt.Errorf("child in crash backoff")

// EntrySnapshot is a read-only view of an entry used by the status handler.
type EntrySnapshot struct {
	TeamID string
	State  string
	PID    int
}

// RegistryConfig holds the tunable parameters for a Registry.
type RegistryConfig struct {
	// MCPServerBin is the path to the upstream mcp-server binary.
	// Defaults to /usr/local/bin/mcp-server.
	MCPServerBin string

	// IdleTimeout is how long an unused child runs before being reaped.
	// Default 10 minutes.
	IdleTimeout time.Duration

	// CrashBackoffBase is the initial backoff duration after a crash.
	// Default 30 seconds. Subsequent crashes double up to CrashBackoffMax.
	CrashBackoffBase time.Duration

	// CrashBackoffMax caps the backoff. Default 300 seconds.
	CrashBackoffMax time.Duration

	// Cipher decrypts xoxc/xoxd blobs from the DB.
	Cipher Decrypter
}

// Decrypter abstracts tokenbridge.Cipher so tests can substitute a no-op.
type Decrypter interface {
	Decrypt(blob []byte) ([]byte, error)
}

// Registry manages per-team child processes.
// The zero value is not usable; construct with NewRegistry.
type Registry struct {
	cfg    RegistryConfig
	reader WorkspaceReader

	mu      sync.RWMutex
	entries map[string]*entry
	crashes map[string]crashRecord // keyed by teamID, guarded by mu
}

// NewRegistry constructs a Registry with the given config and reader.
// Defaults are applied for any zero RegistryConfig fields.
func NewRegistry(reader WorkspaceReader, cfg RegistryConfig) *Registry {
	if cfg.MCPServerBin == "" {
		cfg.MCPServerBin = getenvDefault("MCP_SERVER_BIN", "/usr/local/bin/mcp-server")
	}
	if cfg.IdleTimeout == 0 {
		cfg.IdleTimeout = 10 * time.Minute
	}
	if cfg.CrashBackoffBase == 0 {
		cfg.CrashBackoffBase = 30 * time.Second
	}
	if cfg.CrashBackoffMax == 0 {
		cfg.CrashBackoffMax = 5 * time.Minute
	}
	return &Registry{
		cfg:     cfg,
		reader:  reader,
		entries: make(map[string]*entry),
		crashes: make(map[string]crashRecord),
	}
}

// getenvDefault returns the value of the environment variable k, or def if
// the variable is unset or empty.
func getenvDefault(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// GetOrSpawn returns the running entry for teamID, spawning a new child
// process if none exists.
//
// On first call for a team the function:
//  1. Checks the crash backoff map; returns ErrCrashBackoff if still cooling.
//  2. Looks up workspace credentials from the DB (GetWorkspace).
//  3. Decrypts the xoxc/xoxd tokens.
//  4. Starts the child process.
//  5. Transitions state to RUNNING.
//
// Concurrent first-calls for the same team are safe: the first goroutine
// inserts the entry under Registry.mu and sets state to STARTING; subsequent
// goroutines find the entry in STARTING state and wait (with timeout) for it
// to become RUNNING.
func (reg *Registry) GetOrSpawn(ctx context.Context, teamID string) (*entry, error) {
	// Check crash backoff before any other work.
	reg.mu.RLock()
	cr, hasCrash := reg.crashes[teamID]
	reg.mu.RUnlock()
	if hasCrash && time.Now().Before(cr.nextRetryAt) {
		return nil, ErrCrashBackoff
	}

	// Fast path: entry already running.
	// If the entry is in stateIdle (transient teardown), retry briefly so the
	// caller is not spuriously rejected while the old entry is being reaped.
	const maxIdleRetries = 5
	for i := 0; i < maxIdleRetries; i++ {
		e := reg.getEntry(teamID)
		if e == nil {
			break
		}
		e.mu.Lock()
		s := e.state
		e.mu.Unlock()
		if s == stateIdle {
			// Entry is shutting down; wait briefly then retry the map lookup.
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(50 * time.Millisecond):
			}
			continue
		}
		if err := reg.waitRunning(ctx, e); err != nil {
			return nil, err
		}
		return e, nil
	}

	// Slow path: insert a new entry and spawn.
	e := &entry{teamID: teamID, state: stateStarting, done: make(chan struct{})}
	e.mu.Lock() // hold entry lock before making it visible

	reg.mu.Lock()
	// Double-check: another goroutine may have raced us.
	if existing, ok := reg.entries[teamID]; ok {
		reg.mu.Unlock()
		e.mu.Unlock()
		if err := reg.waitRunning(ctx, existing); err != nil {
			return nil, err
		}
		return existing, nil
	}
	reg.entries[teamID] = e
	reg.mu.Unlock()

	// Spawn outside registry lock, inside entry lock.
	err := reg.spawnLocked(ctx, e)
	e.mu.Unlock()
	if err != nil {
		// Remove the failed entry so the next request retries.
		reg.mu.Lock()
		delete(reg.entries, teamID)
		reg.mu.Unlock()
		return nil, err
	}
	return e, nil
}

// getEntry looks up an entry by teamID under the read lock.
// Returns nil if not found.
func (reg *Registry) getEntry(teamID string) *entry {
	reg.mu.RLock()
	e := reg.entries[teamID]
	reg.mu.RUnlock()
	return e
}

// waitRunning blocks until e.state == stateRunning or the context is done.
// Returns an error if the entry ends up in a non-running state, or if the
// context is cancelled.
//
// Rather than poll-spinning, it selects on e.done (signalled when the child
// exits) with a 50 ms fallback tick, so it wakes promptly on exit events
// while still catching the STARTING→RUNNING transition.
func (reg *Registry) waitRunning(ctx context.Context, e *entry) error {
	deadline := time.Now().Add(10 * time.Second)
	for {
		e.mu.Lock()
		state := e.state
		done := e.done
		e.mu.Unlock()

		switch state {
		case stateRunning:
			return nil
		case stateCrashed:
			return fmt.Errorf("child for team %s is in crashed state", e.teamID)
		case stateIdle:
			return fmt.Errorf("child for team %s is idle (shutting down)", e.teamID)
		}

		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for child %s to start", e.teamID)
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-done:
			// Child exited while we were waiting; re-check state next iteration.
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// spawnLocked launches the child process for e.
// Caller must hold e.mu.
func (reg *Registry) spawnLocked(ctx context.Context, e *entry) error {
	ws, err := reg.reader.GetWorkspace(ctx, e.teamID)
	if err != nil {
		return fmt.Errorf("get workspace %s: %w", e.teamID, err)
	}

	xoxc, err := reg.cfg.Cipher.Decrypt(ws.XoxcEnc)
	if err != nil {
		return fmt.Errorf("decrypt xoxc for team %s: %w", e.teamID, err)
	}
	xoxd, err := reg.cfg.Cipher.Decrypt(ws.XoxdEnc)
	if err != nil {
		return fmt.Errorf("decrypt xoxd for team %s: %w", e.teamID, err)
	}

	// Build child environment: pass token vars plus forwarded host vars.
	childEnv := []string{
		"SLACK_MCP_XOXC_TOKEN=" + string(xoxc),
		"SLACK_MCP_XOXD_TOKEN=" + string(xoxd),
	}
	for _, k := range []string{"SLACK_MCP_ENABLED_TOOLS", "SLACK_MCP_ADD_MESSAGE_TOOL"} {
		if v := os.Getenv(k); v != "" {
			childEnv = append(childEnv, k+"="+v)
		}
	}

	cmd := exec.Command(reg.cfg.MCPServerBin, "--transport", "stdio")
	cmd.Env = childEnv

	// stderr goes to log with a team prefix.
	cmd.Stderr = &prefixWriter{prefix: fmt.Sprintf("[mux team=%s] ", e.teamID)}

	stdinPipe, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("stdin pipe for team %s: %w", e.teamID, err)
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdinPipe.Close()
		return fmt.Errorf("stdout pipe for team %s: %w", e.teamID, err)
	}

	if err := cmd.Start(); err != nil {
		_ = stdinPipe.Close()
		_ = stdoutPipe.Close()
		return fmt.Errorf("start child for team %s: %w", e.teamID, err)
	}

	log.Printf("multiplexer: spawning child team=%s pid=%d", e.teamID, cmd.Process.Pid)

	e.cmd = cmd
	e.stdin = stdinPipe
	e.stdout = stdoutPipe
	e.state = stateRunning
	e.pid = cmd.Process.Pid
	e.lastUsed = time.Now()
	e.lastRefreshedAt = ws.LastRefreshedAt

	// On a successful spawn, clear any prior crash record.
	reg.mu.Lock()
	delete(reg.crashes, e.teamID)
	reg.mu.Unlock()

	// Watch for unexpected exit.
	go reg.watchChild(e)

	return nil
}

// watchChild waits for the child to exit and updates entry state.
// It closes e.done as its last action, which unblocks Teardown and waitRunning.
func (reg *Registry) watchChild(e *entry) {
	defer close(e.done)

	err := e.cmd.Wait()

	e.mu.Lock()
	defer e.mu.Unlock()

	if e.state == stateIdle {
		// Normal graceful teardown initiated by the sweeper or refresh poller.
		log.Printf("multiplexer: child exited team=%s pid=%d (idle teardown)", e.teamID, e.pid)
		reg.mu.Lock()
		delete(reg.entries, e.teamID)
		reg.mu.Unlock()
		return
	}

	// Unexpected crash: record backoff in the Registry so it survives entry deletion.
	reg.mu.Lock()
	cr := reg.crashes[e.teamID]
	cr.count++
	backoff := reg.crashBackoff(cr.count)
	cr.nextRetryAt = time.Now().Add(backoff)
	reg.crashes[e.teamID] = cr
	delete(reg.entries, e.teamID)
	reg.mu.Unlock()

	e.state = stateCrashed
	e.pid = 0
	log.Printf("multiplexer: child crashed team=%s err=%v retry in %s", e.teamID, err, backoff)
}

// crashBackoff returns the backoff duration for the nth crash.
// Doubles from CrashBackoffBase up to CrashBackoffMax.
func (reg *Registry) crashBackoff(n int) time.Duration {
	d := reg.cfg.CrashBackoffBase
	for i := 1; i < n; i++ {
		d *= 2
		if d > reg.cfg.CrashBackoffMax {
			return reg.cfg.CrashBackoffMax
		}
	}
	return d
}

// Teardown sends SIGTERM to the child and waits up to 2 seconds before
// SIGKILLing. It acquires e.mu.
//
// It does NOT call cmd.Wait — that is done exclusively by watchChild.
// Instead it waits on e.done, which watchChild closes after Wait returns.
func (reg *Registry) Teardown(e *entry) {
	e.mu.Lock()

	if e.state != stateRunning {
		e.mu.Unlock()
		return
	}
	e.state = stateIdle
	done := e.done

	log.Printf("multiplexer: idle teardown team=%s", e.teamID)
	_ = e.cmd.Process.Signal(syscall.SIGTERM)
	_ = e.stdin.Close()
	e.pid = 0
	e.mu.Unlock()

	// Wait for watchChild to call cmd.Wait and close done.
	select {
	case <-done:
		// graceful exit
	case <-time.After(2 * time.Second):
		_ = e.cmd.Process.Kill()
		<-done // wait for watchChild to finish after kill
	}

	reg.mu.Lock()
	delete(reg.entries, e.teamID)
	reg.mu.Unlock()
}

// RunIdleSweeper starts a background goroutine that periodically terminates
// children idle for longer than IdleTimeout. It stops when ctx is cancelled.
func (reg *Registry) RunIdleSweeper(ctx context.Context) {
	interval := reg.cfg.IdleTimeout / 2
	if interval < time.Second {
		interval = time.Second
	}
	ticker := time.NewTicker(interval)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				reg.sweepIdle()
			}
		}
	}()
}

// sweepIdle terminates entries whose lastUsed is older than IdleTimeout.
func (reg *Registry) sweepIdle() {
	now := time.Now()
	reg.mu.RLock()
	var stale []*entry
	for _, e := range reg.entries {
		e.mu.Lock()
		if e.state == stateRunning && now.Sub(e.lastUsed) > reg.cfg.IdleTimeout {
			stale = append(stale, e)
		}
		e.mu.Unlock()
	}
	reg.mu.RUnlock()

	for _, e := range stale {
		reg.Teardown(e)
	}
}

// RunRefreshPoller starts a background goroutine that polls WorkspaceReader
// every interval for updated last_refreshed_at values and recycles stale
// children. It stops when ctx is cancelled.
func (reg *Registry) RunRefreshPoller(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				reg.pollRefresh(ctx)
			}
		}
	}()
}

// pollRefresh queries all workspaces and recycles any running child whose
// lastRefreshedAt in the DB has advanced.
func (reg *Registry) pollRefresh(ctx context.Context) {
	workspaces, err := reg.reader.ListWorkspaces(ctx)
	if err != nil {
		log.Printf("multiplexer: refresh poll list workspaces: %v", err)
		return
	}
	for _, ws := range workspaces {
		reg.mu.RLock()
		e := reg.entries[ws.TeamID]
		reg.mu.RUnlock()
		if e == nil {
			continue
		}

		e.mu.Lock()
		needs := e.state == stateRunning && ws.LastRefreshedAt.After(e.lastRefreshedAt)
		e.mu.Unlock()

		if needs {
			log.Printf("multiplexer: token refresh detected team=%s, recycling child", ws.TeamID)
			reg.Teardown(e)
		}
	}
}

// ShutdownAll sends SIGTERM (with SIGKILL fallback) to all running children.
// Called by the main server during graceful shutdown.
func (reg *Registry) ShutdownAll() {
	reg.mu.RLock()
	all := make([]*entry, 0, len(reg.entries))
	for _, e := range reg.entries {
		all = append(all, e)
	}
	reg.mu.RUnlock()

	for _, e := range all {
		reg.Teardown(e)
	}
}

// Snapshot returns a point-in-time view of all known entries.
func (reg *Registry) Snapshot() []EntrySnapshot {
	reg.mu.RLock()
	snaps := make([]EntrySnapshot, 0, len(reg.entries))
	for _, e := range reg.entries {
		e.mu.Lock()
		snaps = append(snaps, EntrySnapshot{
			TeamID: e.teamID,
			State:  e.state.String(),
			PID:    e.pid,
		})
		e.mu.Unlock()
	}
	reg.mu.RUnlock()
	return snaps
}

// Send writes a newline-terminated frame to the child's stdin.
// Caller must hold e.mu.
func (e *entry) Send(frame []byte) error {
	if !strings.HasSuffix(string(frame), "\n") {
		frame = append(frame, '\n')
	}
	_, err := e.stdin.Write(frame)
	return err
}

// prefixWriter is an io.Writer that prepends a fixed prefix to each Write call.
// It splits the input on newlines and emits one log line per non-empty line,
// preventing multi-line stderr output from being logged as a single entry.
// Used to prefix child stderr with [mux team=<team_id>].
type prefixWriter struct {
	prefix string
}

func (pw *prefixWriter) Write(p []byte) (int, error) {
	lines := strings.Split(string(p), "\n")
	for _, line := range lines {
		if line != "" {
			log.Printf("%s%s", pw.prefix, line)
		}
	}
	return len(p), nil
}
