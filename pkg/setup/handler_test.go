package setup_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/korotovsky/slack-mcp-server/pkg/setup"
)

// fakeReader is a test double for WorkspaceStatusReader.
type fakeReader struct {
	workspaces []setup.WorkspaceStatus
	listErr    error
	pingErr    error
}

func (f *fakeReader) ListWorkspaces(_ context.Context) ([]setup.WorkspaceStatus, error) {
	if f.listErr != nil {
		return nil, f.listErr
	}
	return f.workspaces, nil
}

func (f *fakeReader) Ping(_ context.Context) error {
	return f.pingErr
}

const testKey = "test-service-key"
const testBridgeURL = "https://bridge.example.com"
const testHMACKey = "supersecrethmackey"

// minimalUserscript is a tiny stub with the required placeholders.
const minimalUserscript = `// @connect __BRIDGE_HOST__
const BRIDGE_URL = '__BRIDGE_URL__';
const BRIDGE_HMAC_KEY = '__BRIDGE_HMAC_KEY__';`

func newTestHandler(t *testing.T, reader setup.WorkspaceStatusReader) *setup.Handler {
	t.Helper()
	h, err := setup.NewHandler(reader, testKey, testBridgeURL, testHMACKey, minimalUserscript)
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	return h
}

// TestBearerAuth verifies that / requires a valid bearer token.
func TestBearerAuth(t *testing.T) {
	h := newTestHandler(t, &fakeReader{})

	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	t.Run("no auth header", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusUnauthorized {
			t.Errorf("expected 401, got %d", rr.Code)
		}
	})

	t.Run("wrong token", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		req.Header.Set("Authorization", "Bearer wrong-token")
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusUnauthorized {
			t.Errorf("expected 401, got %d", rr.Code)
		}
	})

	t.Run("correct token", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		req.Header.Set("Authorization", "Bearer "+testKey)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Errorf("expected 200, got %d", rr.Code)
		}
	})
}

// TestUserscriptEndpointSubstitution verifies that GET /userscript.user.js
// replaces both placeholders and does not contain the raw placeholder strings.
func TestUserscriptEndpointSubstitution(t *testing.T) {
	h := newTestHandler(t, &fakeReader{})

	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/userscript.user.js", nil)
	req.Header.Set("Authorization", "Bearer "+testKey)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}

	body := rr.Body.String()

	// Placeholders must be replaced.
	for _, p := range []string{"__BRIDGE_URL__", "__BRIDGE_HMAC_KEY__", "__BRIDGE_HOST__"} {
		if strings.Contains(body, p) {
			t.Errorf("placeholder %q was not substituted in served userscript", p)
		}
	}

	// Actual values must appear.
	if !strings.Contains(body, testBridgeURL) {
		t.Errorf("expected BRIDGE_URL %q in served userscript", testBridgeURL)
	}
	if !strings.Contains(body, testHMACKey) {
		t.Errorf("expected BRIDGE_HMAC_KEY %q in served userscript", testHMACKey)
	}
	// Host portion (without scheme) is what feeds @connect.
	if !strings.Contains(body, "bridge.example.com") {
		t.Errorf("expected bridge host 'bridge.example.com' in @connect directive")
	}

	ct := rr.Header().Get("Content-Type")
	if !strings.HasPrefix(ct, "application/javascript") {
		t.Errorf("expected Content-Type application/javascript, got %q", ct)
	}
}

// TestIndexRendersStatusTable verifies that GET / renders HTML containing
// a table when workspaces exist.
func TestIndexRendersStatusTable(t *testing.T) {
	reader := &fakeReader{
		workspaces: []setup.WorkspaceStatus{
			{
				TeamID:          "T12345",
				TeamName:        "Acme Corp",
				LastRefreshedAt: time.Now().UTC().Add(-30 * time.Minute),
			},
		},
	}
	h := newTestHandler(t, reader)

	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Authorization", "Bearer "+testKey)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}

	body := rr.Body.String()
	if !strings.Contains(body, "T12345") {
		t.Errorf("expected team ID T12345 in rendered HTML")
	}
	if !strings.Contains(body, "Acme Corp") {
		t.Errorf("expected team name 'Acme Corp' in rendered HTML")
	}
	if !strings.Contains(body, "<table") {
		t.Errorf("expected <table> element in rendered HTML")
	}
}

// TestIndexNoWorkspaces verifies that GET / renders the no-workspaces message.
func TestIndexNoWorkspaces(t *testing.T) {
	h := newTestHandler(t, &fakeReader{workspaces: nil})

	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Authorization", "Bearer "+testKey)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}

	body := rr.Body.String()
	if !strings.Contains(body, "No workspaces") {
		t.Errorf("expected 'No workspaces' message in rendered HTML when no rows exist")
	}
}

// TestHealthEndpoint verifies /_health does not require auth and returns the
// correct status based on Ping outcome.
func TestHealthEndpoint(t *testing.T) {
	t.Run("healthy", func(t *testing.T) {
		h := newTestHandler(t, &fakeReader{pingErr: nil})
		mux := http.NewServeMux()
		h.RegisterRoutes(mux)

		req := httptest.NewRequest(http.MethodGet, "/_health", nil)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)

		if rr.Code != http.StatusOK {
			t.Errorf("expected 200, got %d", rr.Code)
		}
		var resp map[string]string
		if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
			t.Fatalf("decode health response: %v", err)
		}
		if resp["status"] != "ok" {
			t.Errorf("expected status=ok, got %q", resp["status"])
		}
	})

	t.Run("unhealthy — no auth required", func(t *testing.T) {
		h := newTestHandler(t, &fakeReader{pingErr: errFakePing})
		mux := http.NewServeMux()
		h.RegisterRoutes(mux)

		req := httptest.NewRequest(http.MethodGet, "/_health", nil)
		// Deliberately no Authorization header.
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)

		if rr.Code != http.StatusServiceUnavailable {
			t.Errorf("expected 503, got %d", rr.Code)
		}
	})
}

// errFakePing is a sentinel error used by the unhealthy fakeReader.
var errFakePing = &fakeError{"db ping failed"}

type fakeError struct{ msg string }

func (e *fakeError) Error() string { return e.msg }

// TestUserscriptEndpointAuth verifies that GET /userscript.user.js requires
// bearer auth — the route serves BRIDGE_HMAC_KEY and must never respond
// unauthenticated, regardless of refactors to the auth middleware.
func TestUserscriptEndpointAuth(t *testing.T) {
	h := newTestHandler(t, &fakeReader{})
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	t.Run("no auth header", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/userscript.user.js", nil)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusUnauthorized {
			t.Errorf("expected 401, got %d", rr.Code)
		}
		if strings.Contains(rr.Body.String(), testHMACKey) {
			t.Errorf("HMAC key leaked in unauthenticated response body")
		}
	})

	t.Run("wrong token", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/userscript.user.js", nil)
		req.Header.Set("Authorization", "Bearer wrong-token")
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusUnauthorized {
			t.Errorf("expected 401, got %d", rr.Code)
		}
	})
}

// TestIndexListWorkspacesError verifies that a DB-level failure surfaces as
// HTTP 500 rather than a partially rendered page.
func TestIndexListWorkspacesError(t *testing.T) {
	reader := &fakeReader{listErr: errFakePing}
	h := newTestHandler(t, reader)
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Authorization", "Bearer "+testKey)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Errorf("expected 500, got %d", rr.Code)
	}
}

// TestIndexCatchAllRejectsUnknownPaths covers FU4 from the slack-mcp-server#9
// review: `mux.Handle("/", ...)` is a catch-all, and without an explicit
// path guard every unknown path would render the index. handleIndex must
// 404 anything that isn't exactly "/".
func TestIndexCatchAllRejectsUnknownPaths(t *testing.T) {
	h := newTestHandler(t, &fakeReader{})
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	cases := []string{
		"/typo",
		"/admin",
		"/anything",
		"/foo/bar",
	}
	for _, path := range cases {
		t.Run(path, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, path, nil)
			req.Header.Set("Authorization", "Bearer "+testKey)
			rr := httptest.NewRecorder()
			mux.ServeHTTP(rr, req)
			if rr.Code != http.StatusNotFound {
				t.Errorf("path %q: expected 404, got %d", path, rr.Code)
			}
		})
	}

	// Sanity: "/" itself still renders.
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Authorization", "Bearer "+testKey)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Errorf("/ expected 200, got %d", rr.Code)
	}
}

// TestUserscriptDownloadURLSubstitution covers FU3 from the
// slack-mcp-server#9 review: the templated userscript must include a
// @downloadURL pointing back at the setup service so users (and
// Tampermonkey) know where to refetch a fresh copy. The placeholder
// must be substituted with the request's scheme + host.
func TestUserscriptDownloadURLSubstitution(t *testing.T) {
	// Add the new placeholder to the minimal stub so this file can
	// exercise it independently. Template strings in tests are
	// allowed to differ from the production userscript.
	const stubWithDownloadURL = `// @connect __BRIDGE_HOST__
// @downloadURL __DOWNLOAD_URL__
const BRIDGE_URL = '__BRIDGE_URL__';
const BRIDGE_HMAC_KEY = '__BRIDGE_HMAC_KEY__';`

	h, err := setup.NewHandler(&fakeReader{}, testKey, testBridgeURL, testHMACKey, stubWithDownloadURL)
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/userscript.user.js", nil)
	req.Host = "setup.tail.ts.net:13083"
	req.Header.Set("Authorization", "Bearer "+testKey)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	want := "http://setup.tail.ts.net:13083/userscript.user.js"
	if !strings.Contains(body, want) {
		t.Errorf("@downloadURL not substituted; expected %q in body, body=%q", want, body)
	}
	if strings.Contains(body, "__DOWNLOAD_URL__") {
		t.Errorf("placeholder __DOWNLOAD_URL__ left in body: %q", body)
	}
}

// Same as above but exercising the X-Forwarded-Proto path so the
// rendered @downloadURL is https when fronted by a TLS terminator
// (e.g. Tailscale Serve).
func TestUserscriptDownloadURLSubstitution_HTTPS(t *testing.T) {
	const stubWithDownloadURL = `// @downloadURL __DOWNLOAD_URL__`
	h, err := setup.NewHandler(&fakeReader{}, testKey, testBridgeURL, testHMACKey, stubWithDownloadURL)
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/userscript.user.js", nil)
	req.Host = "setup.example.com"
	req.Header.Set("X-Forwarded-Proto", "https")
	req.Header.Set("Authorization", "Bearer "+testKey)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	body := rr.Body.String()
	want := "https://setup.example.com/userscript.user.js"
	if !strings.Contains(body, want) {
		t.Errorf("@downloadURL HTTPS path not substituted; expected %q in body, body=%q", want, body)
	}
}
