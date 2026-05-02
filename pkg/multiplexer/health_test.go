package multiplexer

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

// pingErrorReader is a WorkspaceReader whose Ping always returns an error.
type pingErrorReader struct {
	fakeReader
}

func (r *pingErrorReader) Ping(_ context.Context) error {
	return errors.New("db unavailable")
}

func TestHealthHandler_OK(t *testing.T) {
	reader := newFakeReader()
	handler := HealthHandler(reader)

	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/_health", nil)
	handler.ServeHTTP(w, r)

	if w.Code != http.StatusOK {
		t.Errorf("status: got %d want 200", w.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body["status"] != "ok" {
		t.Errorf("status field: got %q want ok", body["status"])
	}
}

func TestHealthHandler_Unhealthy(t *testing.T) {
	reader := &pingErrorReader{}
	handler := HealthHandler(reader)

	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/_health", nil)
	handler.ServeHTTP(w, r)

	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("status: got %d want 503", w.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body["status"] != "unhealthy" {
		t.Errorf("status field: got %q want unhealthy", body["status"])
	}
}

func TestStatusHandler_Unauthorized(t *testing.T) {
	reader := newFakeReader()
	reg := makeRegistry(reader)
	handler := StatusHandler(reg, testServiceKey)

	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/_status", nil)
	// No Authorization header.
	handler.ServeHTTP(w, r)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("status: got %d want 401", w.Code)
	}
}

func TestStatusHandler_Empty(t *testing.T) {
	reader := newFakeReader()
	reg := makeRegistry(reader)
	handler := StatusHandler(reg, testServiceKey)

	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/_status", nil)
	r.Header.Set("Authorization", "Bearer "+testServiceKey)
	handler.ServeHTTP(w, r)

	if w.Code != http.StatusOK {
		t.Errorf("status: got %d want 200", w.Code)
	}

	var resp struct {
		Teams []EntrySnapshot `json:"teams"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(resp.Teams) != 0 {
		t.Errorf("teams: got %d want 0", len(resp.Teams))
	}
}

func TestStatusHandler_WithChild(t *testing.T) {
	reader := newFakeReader(ws("T200"))
	reg := makeRegistry(reader)

	ctx := context.Background()
	_, err := reg.GetOrSpawn(ctx, "T200")
	if err != nil {
		t.Fatalf("GetOrSpawn: %v", err)
	}
	defer reg.ShutdownAll()

	handler := StatusHandler(reg, testServiceKey)
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/_status", nil)
	r.Header.Set("Authorization", "Bearer "+testServiceKey)
	handler.ServeHTTP(w, r)

	if w.Code != http.StatusOK {
		t.Errorf("status: got %d want 200", w.Code)
	}
	var resp struct {
		Teams []EntrySnapshot `json:"teams"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(resp.Teams) != 1 {
		t.Fatalf("teams: got %d want 1", len(resp.Teams))
	}
	if resp.Teams[0].TeamID != "T200" {
		t.Errorf("team_id: got %q want T200", resp.Teams[0].TeamID)
	}
	if resp.Teams[0].State != "running" {
		t.Errorf("state: got %q want running", resp.Teams[0].State)
	}
}
