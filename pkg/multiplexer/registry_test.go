package multiplexer

import (
	"bufio"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"testing"
	"time"
)

// fakeChildBin holds the path to the compiled fake-mcp-server binary.
// Built once in TestMain.
var fakeChildBin string

func TestMain(m *testing.M) {
	// Build fake-mcp-server into a temp directory.
	dir, err := os.MkdirTemp("", "fake-mcp-server-*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "tempdir: %v\n", err)
		os.Exit(1)
	}
	defer os.RemoveAll(dir)

	bin := dir + "/fake-mcp-server"
	cmd := exec.Command("go", "build", "-o", bin, "./testdata/fake-mcp-server")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "build fake-mcp-server: %v\n", err)
		os.Exit(1)
	}
	fakeChildBin = bin

	os.Exit(m.Run())
}

// noopDecrypter returns the blob unchanged — suitable for tests that store
// plaintext as the encrypted blob.
type noopDecrypter struct{}

func (noopDecrypter) Decrypt(blob []byte) ([]byte, error) { return blob, nil }

// fakeReader implements WorkspaceReader with an in-memory map.
type fakeReader struct {
	mu         sync.Mutex
	workspaces map[string]Workspace
}

func newFakeReader(workspaces ...Workspace) *fakeReader {
	fr := &fakeReader{workspaces: make(map[string]Workspace)}
	for _, w := range workspaces {
		fr.workspaces[w.TeamID] = w
	}
	return fr
}

func (r *fakeReader) SetWorkspace(w Workspace) {
	r.mu.Lock()
	r.workspaces[w.TeamID] = w
	r.mu.Unlock()
}

func (r *fakeReader) ListWorkspaces(_ context.Context) ([]Workspace, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]Workspace, 0, len(r.workspaces))
	for _, w := range r.workspaces {
		out = append(out, w)
	}
	return out, nil
}

func (r *fakeReader) GetWorkspace(_ context.Context, teamID string) (Workspace, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	w, ok := r.workspaces[teamID]
	if !ok {
		return Workspace{}, sql.ErrNoRows
	}
	return w, nil
}

func (r *fakeReader) Ping(_ context.Context) error { return nil }

// makeRegistry returns a Registry wired up with the fake child binary and
// the supplied fake reader.
func makeRegistry(reader WorkspaceReader) *Registry {
	return NewRegistry(reader, RegistryConfig{
		MCPServerBin:     fakeChildBin,
		IdleTimeout:      500 * time.Millisecond,
		CrashBackoffBase: 50 * time.Millisecond,
		CrashBackoffMax:  200 * time.Millisecond,
		Cipher:           noopDecrypter{},
	})
}

// ws is a helper to build a Workspace with plaintext tokens (noopDecrypter).
func ws(teamID string) Workspace {
	return Workspace{
		TeamID:          teamID,
		TeamName:        teamID,
		XoxcEnc:         []byte("xoxc-test"),
		XoxdEnc:         []byte("xoxd-test"),
		LastRefreshedAt: time.Now(),
	}
}

// TestLazySpawn verifies that GetOrSpawn starts the child on first request
// and returns a running entry.
func TestLazySpawn(t *testing.T) {
	reader := newFakeReader(ws("T001"))
	reg := makeRegistry(reader)

	ctx := context.Background()
	e, err := reg.GetOrSpawn(ctx, "T001")
	if err != nil {
		t.Fatalf("GetOrSpawn: %v", err)
	}
	if e == nil {
		t.Fatal("expected non-nil entry")
	}
	e.mu.Lock()
	state := e.state
	pid := e.pid
	e.mu.Unlock()

	if state != stateRunning {
		t.Errorf("state: got %v want running", state)
	}
	if pid == 0 {
		t.Errorf("pid should not be 0")
	}

	// Cleanup.
	reg.ShutdownAll()
}

// TestConcurrentFirstRequest verifies that two goroutines racing the first
// GetOrSpawn for the same team result in exactly one child process.
func TestConcurrentFirstRequest(t *testing.T) {
	reader := newFakeReader(ws("T002"))
	reg := makeRegistry(reader)

	ctx := context.Background()
	var wg sync.WaitGroup
	results := make([]*entry, 2)
	errors := make([]error, 2)

	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			results[idx], errors[idx] = reg.GetOrSpawn(ctx, "T002")
		}(i)
	}
	wg.Wait()

	for i, err := range errors {
		if err != nil {
			t.Fatalf("goroutine %d: GetOrSpawn: %v", i, err)
		}
	}

	// Both goroutines should return entries pointing to the same pid.
	results[0].mu.Lock()
	pid0 := results[0].pid
	results[0].mu.Unlock()

	results[1].mu.Lock()
	pid1 := results[1].pid
	results[1].mu.Unlock()

	if pid0 != pid1 {
		t.Errorf("two children spawned (pid0=%d pid1=%d); expected exactly one", pid0, pid1)
	}

	reg.ShutdownAll()
}

// TestIdleTeardown verifies that the sweeper removes idle children.
func TestIdleTeardown(t *testing.T) {
	reader := newFakeReader(ws("T003"))
	reg := makeRegistry(reader)
	defer reg.ShutdownAll()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	e, err := reg.GetOrSpawn(ctx, "T003")
	if err != nil {
		t.Fatalf("GetOrSpawn: %v", err)
	}

	// Force lastUsed to the past so the sweeper considers it idle.
	e.mu.Lock()
	e.lastUsed = time.Now().Add(-10 * time.Second)
	e.mu.Unlock()

	reg.RunIdleSweeper(ctx)

	// Wait for the sweeper to fire (interval = idleTimeout/2 = 250ms).
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		reg.mu.RLock()
		_, still := reg.entries["T003"]
		reg.mu.RUnlock()
		if !still {
			return // swept successfully
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Error("entry was not swept after idle timeout")
}

// TestCrashBackoff verifies that:
//  1. A child crash removes the entry from the registry.
//  2. An immediate retry returns ErrCrashBackoff (503-equivalent).
//  3. After the backoff window expires, GetOrSpawn succeeds again.
func TestCrashBackoff(t *testing.T) {
	reader := newFakeReader(ws("T004"))
	reg := makeRegistry(reader)
	defer reg.ShutdownAll()

	ctx := context.Background()
	e, err := reg.GetOrSpawn(ctx, "T004")
	if err != nil {
		t.Fatalf("GetOrSpawn: %v", err)
	}

	// Capture the done channel before killing; kill the child abruptly.
	e.mu.Lock()
	proc := e.cmd.Process
	done := e.done
	e.mu.Unlock()

	_ = proc.Kill()

	// Wait for watchChild to process the exit and delete the entry.
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("watchChild did not finish within 2s")
	}

	// Give watchChild time to update the crashes map (it runs after Wait).
	time.Sleep(10 * time.Millisecond)

	// Verify entry was removed from the registry.
	reg.mu.RLock()
	_, still := reg.entries["T004"]
	reg.mu.RUnlock()
	if still {
		t.Fatal("entry should have been removed after crash")
	}

	// Immediate retry must be blocked by crash backoff.
	_, err = reg.GetOrSpawn(ctx, "T004")
	if !errors.Is(err, ErrCrashBackoff) {
		t.Fatalf("expected ErrCrashBackoff immediately after crash, got: %v", err)
	}

	// CrashBackoffBase is 50ms in makeRegistry; wait just past that.
	time.Sleep(70 * time.Millisecond)

	// After backoff expires, GetOrSpawn should succeed.
	e2, err := reg.GetOrSpawn(ctx, "T004")
	if err != nil {
		t.Fatalf("GetOrSpawn after backoff: %v", err)
	}
	e2.mu.Lock()
	state := e2.state
	e2.mu.Unlock()
	if state != stateRunning {
		t.Errorf("expected running after backoff, got %v", state)
	}
}

// TestTokenRefreshRecycles verifies that the refresh poller tears down a child
// when the DB shows an updated last_refreshed_at.
func TestTokenRefreshRecycles(t *testing.T) {
	now := time.Now()
	w := Workspace{
		TeamID:          "T005",
		TeamName:        "T005",
		XoxcEnc:         []byte("xoxc-test"),
		XoxdEnc:         []byte("xoxd-test"),
		LastRefreshedAt: now,
	}
	reader := newFakeReader(w)
	reg := makeRegistry(reader)

	ctx := context.Background()
	e, err := reg.GetOrSpawn(ctx, "T005")
	if err != nil {
		t.Fatalf("GetOrSpawn: %v", err)
	}

	// Simulate a token refresh: advance last_refreshed_at in the fake reader.
	w.LastRefreshedAt = now.Add(1 * time.Second)
	reader.SetWorkspace(w)

	// Run one poll cycle.
	reg.pollRefresh(ctx)

	// Entry should have been removed.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		reg.mu.RLock()
		_, still := reg.entries["T005"]
		reg.mu.RUnlock()
		if !still {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = e // suppress unused
	t.Error("entry not recycled after token refresh")
}

// TestRelayTransparent verifies that bytes written to a child's stdin come
// back verbatim on stdout (fake-mcp-server echoes each line).
func TestRelayTransparent(t *testing.T) {
	reader := newFakeReader(ws("T006"))
	reg := makeRegistry(reader)

	ctx := context.Background()
	e, err := reg.GetOrSpawn(ctx, "T006")
	if err != nil {
		t.Fatalf("GetOrSpawn: %v", err)
	}

	frame := `{"jsonrpc":"2.0","id":1,"method":"ping"}`

	e.mu.Lock()
	if err := e.Send([]byte(frame)); err != nil {
		e.mu.Unlock()
		t.Fatalf("Send: %v", err)
	}

	// Read response from child stdout.
	stdout := e.stdout
	e.mu.Unlock()

	// Use a buffered reader with a read timeout via a goroutine.
	type result struct {
		line string
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		scanner := bufio.NewScanner(stdout.(io.Reader))
		if scanner.Scan() {
			ch <- result{line: scanner.Text()}
		} else {
			ch <- result{err: scanner.Err()}
		}
	}()

	select {
	case r := <-ch:
		if r.err != nil {
			t.Fatalf("read stdout: %v", r.err)
		}
		if r.line != frame {
			t.Errorf("relay mismatch: got %q want %q", r.line, frame)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timeout waiting for child stdout")
	}

	reg.ShutdownAll()
}
