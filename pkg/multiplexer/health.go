package multiplexer

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"time"
)

// HealthHandler returns an http.Handler for GET /_health.
//
// Returns 200 {"status":"ok"} when reader.Ping succeeds and
// 503 {"status":"unhealthy"} otherwise. The DB ping is bounded by a
// 2-second context so a hung database cannot stall the health probe.
func HealthHandler(reader WorkspaceReader) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()

		if err := reader.Ping(ctx); err != nil {
			writeHealthJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unhealthy"})
			return
		}
		writeHealthJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
}

// statusResponse is the JSON body returned by GET /_status.
type statusResponse struct {
	Teams []EntrySnapshot `json:"teams"`
}

// StatusHandler returns an http.Handler for GET /_status.
//
// The endpoint is admin-only (same bearer auth as the proxy handler). It
// returns a point-in-time snapshot of per-team child states and PIDs.
func StatusHandler(reg *Registry, serviceKey string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		if !bearerTokenValid(r, serviceKey) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		snaps := reg.Snapshot()
		if snaps == nil {
			snaps = []EntrySnapshot{}
		}
		writeHealthJSON(w, http.StatusOK, statusResponse{Teams: snaps})
	})
}

// writeHealthJSON serialises v as JSON with the given status code.
func writeHealthJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("multiplexer: write health response: %v", err)
	}
}
