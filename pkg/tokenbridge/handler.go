package tokenbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"time"
)

// WorkspaceStore is the subset of *Store needed by the HTTP handlers. It
// is declared here so handler tests can substitute a fake without bringing
// up a real database.
type WorkspaceStore interface {
	UpsertWorkspace(
		ctx context.Context,
		teamID, teamName string,
		xoxcEnc, xoxdEnc []byte,
		capturedAt time.Time,
	) (bool, string, error)

	WriteAudit(
		ctx context.Context,
		teamID, event string,
		capturedAt time.Time,
		sourceIP, userAgent string,
	) error

	Ping(ctx context.Context) error
}

// refreshRequest is the JSON body posted by the userscript.
type refreshRequest struct {
	TeamID     string    `json:"team_id"`
	TeamName   string    `json:"team_name"`
	Xoxc       string    `json:"xoxc"`
	Xoxd       string    `json:"xoxd"`
	CapturedAt time.Time `json:"captured_at"`
	Nonce      string    `json:"nonce"`
}

// refreshResponse is the JSON body returned to the userscript.
type refreshResponse struct {
	Stored bool   `json:"stored"`
	TeamID string `json:"team_id"`
	Reason string `json:"reason,omitempty"`
}

// Event names recorded in audit_log.
const (
	eventRefreshed    = "refreshed"
	eventSkippedStale = "skipped_stale"
)

// futureSkew is how far in the future a captured_at may be before the
// request is rejected. Tighter than the replay window in the past
// direction so we don't let pre-signed payloads stockpile.
const futureSkew = 1 * time.Minute

// pastSkew is how far in the past a captured_at may be. Anything older
// is rejected outright (independent of DB-level stale-skip, which is
// per-team monotonic).
const pastSkew = 5 * time.Minute

// RefreshHandler returns an http.Handler for POST /api/tokens/refresh.
//
// hmacKey authenticates the userscript; cipher encrypts the xoxc/xoxd
// pair at rest. Both must be non-zero.
func RefreshHandler(store WorkspaceStore, hmacKey []byte, cipher *Cipher) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		// Read body up to 64 KiB. xoxc+xoxd are well under 1 KiB combined;
		// anything larger is malformed or hostile.
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64*1024))
		if err != nil {
			http.Error(w, "read body", http.StatusBadRequest)
			return
		}

		// Verify HMAC signature against raw body BEFORE parsing. Any
		// per-byte change must fail authentication.
		sig := r.Header.Get(SignatureHeader)
		if sig == "" {
			http.Error(w, "missing signature", http.StatusUnauthorized)
			return
		}
		if err := VerifySignature(hmacKey, body, sig); err != nil {
			http.Error(w, "invalid signature", http.StatusUnauthorized)
			return
		}

		var req refreshRequest
		dec := json.NewDecoder(bytes.NewReader(body))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&req); err != nil {
			http.Error(w, "malformed body", http.StatusBadRequest)
			return
		}

		// Defence-in-depth: require the X-Bridge-Nonce header to equal
		// the body's nonce. Prevents a captured signed body from being
		// blindly proxied through a different transport.
		nonceHeader := r.Header.Get(NonceHeader)
		if nonceHeader == "" || req.Nonce == "" || nonceHeader != req.Nonce {
			http.Error(w, "nonce mismatch", http.StatusUnauthorized)
			return
		}

		if req.TeamID == "" || req.Xoxc == "" || req.Xoxd == "" {
			http.Error(w, "missing required fields", http.StatusBadRequest)
			return
		}

		// Replay window: reject captured_at too far in the past or
		// (mildly) in the future.
		now := time.Now().UTC()
		if req.CapturedAt.IsZero() ||
			now.Sub(req.CapturedAt) > pastSkew ||
			req.CapturedAt.Sub(now) > futureSkew {
			http.Error(w, "captured_at outside acceptable window", http.StatusBadRequest)
			return
		}

		xoxcEnc, err := cipher.Encrypt([]byte(req.Xoxc))
		if err != nil {
			log.Printf("token-bridge: encrypt xoxc team=%s: %v", req.TeamID, err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		xoxdEnc, err := cipher.Encrypt([]byte(req.Xoxd))
		if err != nil {
			log.Printf("token-bridge: encrypt xoxd team=%s: %v", req.TeamID, err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		stored, reason, err := store.UpsertWorkspace(
			r.Context(),
			req.TeamID, req.TeamName,
			xoxcEnc, xoxdEnc,
			req.CapturedAt,
		)
		if err != nil {
			log.Printf("token-bridge: upsert team=%s: %v", req.TeamID, err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		event := eventRefreshed
		if !stored {
			event = eventSkippedStale
		}
		if auditErr := store.WriteAudit(
			r.Context(),
			req.TeamID, event,
			req.CapturedAt,
			clientIP(r), r.UserAgent(),
		); auditErr != nil {
			// Audit failures should not fail the request. Log and continue.
			log.Printf("token-bridge: audit team=%s event=%s: %v", req.TeamID, event, auditErr)
		}

		writeJSON(w, http.StatusOK, refreshResponse{
			Stored: stored,
			TeamID: req.TeamID,
			Reason: reason,
		})
	})
}

// HealthHandler returns an http.Handler for GET /_health.
//
// Returns 200 {"status":"ok"} when store.Ping succeeds and 503
// {"status":"unhealthy"} otherwise. The DB ping is bounded with a 2-second
// timeout so a hung database doesn't pin the orchestrator's health probe.
func HealthHandler(store WorkspaceStore) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()

		if err := store.Ping(ctx); err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unhealthy"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
}

// writeJSON serialises v to w with the given status. Errors are logged
// but cannot be reported to the client by that point.
func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("token-bridge: write response: %v", err)
	}
}

// clientIP extracts the requester's IP for audit purposes. We trust
// X-Forwarded-For only as the leftmost entry (CapRover/Caddy add it on
// our edge); otherwise fall back to RemoteAddr. Returns "" if the parsed
// value is not a valid IP — audit_log.source_ip is `inet`, which would
// reject malformed strings outright.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		head := xff
		if i := strings.IndexByte(xff, ','); i >= 0 {
			head = xff[:i]
		}
		head = strings.TrimSpace(head)
		if net.ParseIP(head) != nil {
			return head
		}
		return ""
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if net.ParseIP(host) != nil {
		return host
	}
	return ""
}

// Compile-time guard: *Store must satisfy WorkspaceStore.
var _ WorkspaceStore = (*Store)(nil)
