package multiplexer

import (
	"context"
	"database/sql"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testServiceKey = "test-service-key-xyz"

func newProxyServer(t *testing.T, reader WorkspaceReader) (*httptest.Server, *Registry) {
	t.Helper()
	reg := NewRegistry(reader, RegistryConfig{
		MCPServerBin:     fakeChildBin,
		IdleTimeout:      30 * time.Second,
		CrashBackoffBase: 50 * time.Millisecond,
		CrashBackoffMax:  200 * time.Millisecond,
		Cipher:           noopDecrypter{},
	})
	mux := http.NewServeMux()
	mux.Handle("/teams/", ProxyHandler(reg, testServiceKey))
	srv := httptest.NewServer(mux)
	t.Cleanup(func() {
		srv.Close()
		reg.ShutdownAll()
	})
	return srv, reg
}

func TestProxyHandler_MissingBearer(t *testing.T) {
	reader := newFakeReader(ws("T100"))
	srv, _ := newProxyServer(t, reader)

	resp, err := http.Post(srv.URL+"/teams/T100/mcp", "application/json",
		strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	if err != nil {
		t.Fatalf("Post: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status: got %d want 401", resp.StatusCode)
	}
}

func TestProxyHandler_InvalidBearer(t *testing.T) {
	reader := newFakeReader(ws("T101"))
	srv, _ := newProxyServer(t, reader)

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/teams/T101/mcp",
		strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	req.Header.Set("Authorization", "Bearer wrong-key")
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status: got %d want 401", resp.StatusCode)
	}
}

func TestProxyHandler_UnknownTeam(t *testing.T) {
	reader := newFakeReader() // empty — no teams
	srv, _ := newProxyServer(t, reader)

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/teams/TNOTEXIST/mcp",
		strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	req.Header.Set("Authorization", "Bearer "+testServiceKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("status: got %d want 404", resp.StatusCode)
	}
}

func TestProxyHandler_ValidCall(t *testing.T) {
	reader := newFakeReader(ws("T102"))
	srv, _ := newProxyServer(t, reader)

	frame := `{"jsonrpc":"2.0","id":42,"method":"ping"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/teams/T102/mcp",
		strings.NewReader(frame))
	req.Header.Set("Authorization", "Bearer "+testServiceKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Errorf("status: got %d want 200", resp.StatusCode)
	}

	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	got := strings.TrimSpace(string(bodyBytes))
	if got != frame {
		t.Errorf("body mismatch:\n  got  %q\n  want %q", got, frame)
	}
}

// TestProxyHandler_DBErrorDuringSpawn verifies that a non-NoRows DB error
// during GetOrSpawn causes the proxy to return 503.
func TestProxyHandler_DBErrorDuringSpawn(t *testing.T) {
	// errReader.GetWorkspace returns a non-NoRows error to simulate a DB failure.
	reader := &errReader{}
	reg := NewRegistry(reader, RegistryConfig{
		MCPServerBin:     fakeChildBin,
		IdleTimeout:      30 * time.Second,
		CrashBackoffBase: 50 * time.Millisecond,
		CrashBackoffMax:  200 * time.Millisecond,
		Cipher:           noopDecrypter{},
	})
	mux := http.NewServeMux()
	mux.Handle("/teams/", ProxyHandler(reg, testServiceKey))
	srv := httptest.NewServer(mux)
	defer srv.Close()
	defer reg.ShutdownAll()

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/teams/TCRASH/mcp",
		strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	req.Header.Set("Authorization", "Bearer "+testServiceKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	resp.Body.Close()
	// GetWorkspace returns a non-NoRows error → GetOrSpawn fails → 503.
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("status: got %d want 503", resp.StatusCode)
	}
}

// TestProxyHandler_ChildCrashMidRequest verifies that killing the child
// process while a request is in-flight causes the proxy to return 503
// rather than hanging or panicking.
//
// Strategy: use a long CrashBackoffBase (5s) so the backoff window is still
// active when the HTTP request arrives, guaranteeing a 503 from ErrCrashBackoff.
func TestProxyHandler_ChildCrashMidRequest(t *testing.T) {
	reader := newFakeReader(ws("TCRASH2"))
	reg := NewRegistry(reader, RegistryConfig{
		MCPServerBin:     fakeChildBin,
		IdleTimeout:      30 * time.Second,
		CrashBackoffBase: 5 * time.Second, // long enough to still be active
		CrashBackoffMax:  30 * time.Second,
		Cipher:           noopDecrypter{},
	})
	defer reg.ShutdownAll()

	ctx := context.Background()

	// Spawn the child so it is running.
	e, err := reg.GetOrSpawn(ctx, "TCRASH2")
	if err != nil {
		t.Fatalf("GetOrSpawn: %v", err)
	}

	// Kill the child directly — simulates a crash mid-request.
	e.mu.Lock()
	proc := e.cmd.Process
	done := e.done
	e.mu.Unlock()
	_ = proc.Kill()

	// Wait for watchChild to finish (records crash backoff).
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("watchChild did not finish within 2s")
	}

	// Issue a request immediately after the crash; the backoff window (5s) is
	// still active, so GetOrSpawn must return ErrCrashBackoff → 503.
	mux := http.NewServeMux()
	mux.Handle("/teams/", ProxyHandler(reg, testServiceKey))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/teams/TCRASH2/mcp",
		strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	req.Header.Set("Authorization", "Bearer "+testServiceKey)
	req.Header.Set("Content-Type", "application/json")

	// Use a short client timeout to catch any accidental hangs.
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("status: got %d want 503", resp.StatusCode)
	}
}

// errReader simulates a DB error on GetWorkspace (not sql.ErrNoRows),
// which causes the proxy handler to return 503.
type errReader struct{}

func (r *errReader) ListWorkspaces(_ context.Context) ([]Workspace, error) { return nil, nil }
func (r *errReader) GetWorkspace(_ context.Context, _ string) (Workspace, error) {
	return Workspace{}, sql.ErrConnDone // non-NoRows error
}
func (r *errReader) Ping(_ context.Context) error { return nil }
