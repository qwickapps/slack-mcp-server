package multiplexer

import (
	"bufio"
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

// ProxyHandler returns an http.Handler for POST /teams/{team_id}/mcp.
//
// The handler:
//  1. Verifies the Authorization: Bearer header against serviceKey using
//     constant-time compare.
//  2. Extracts the team_id from the URL path.
//  3. Calls registry.GetOrSpawn to obtain or start the per-team child.
//  4. Writes the request body (the opaque MCP frame) to the child's stdin.
//  5. Reads one newline-terminated response from the child's stdout.
//  6. Writes the response to the HTTP caller.
//
// The request body is limited to maxBodyBytes to prevent runaway allocations.
func ProxyHandler(reg *Registry, serviceKey string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		// Auth check first — extractTeamID is deferred until auth passes so we
		// do not parse the URL for unauthenticated requests.
		if !bearerTokenValid(r, serviceKey) {
			ip := clientIPStr(r)
			log.Printf("multiplexer: unauthorized ip=%s", ip)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		teamID := extractTeamID(r.URL.Path)
		if teamID == "" {
			http.Error(w, "missing team_id", http.StatusBadRequest)
			return
		}

		// Read body (opaque MCP frame).
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
		if err != nil {
			http.Error(w, "read body", http.StatusBadRequest)
			return
		}
		if len(body) == 0 {
			http.Error(w, "empty body", http.StatusBadRequest)
			return
		}

		// Obtain (or spawn) the child for this team.
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()

		e, err := reg.GetOrSpawn(ctx, teamID)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeJSONMsg(w, http.StatusNotFound, "unknown team")
				return
			}
			if errors.Is(err, ErrCrashBackoff) {
				log.Printf("multiplexer team=%s: crash backoff active", teamID)
				http.Error(w, "service unavailable", http.StatusServiceUnavailable)
				return
			}
			log.Printf("multiplexer team=%s: GetOrSpawn: %v", teamID, err)
			http.Error(w, "service unavailable", http.StatusServiceUnavailable)
			return
		}

		// Serialise access to this entry (one request at a time per team).
		e.mu.Lock()
		defer e.mu.Unlock()

		if e.state != stateRunning {
			http.Error(w, "service unavailable", http.StatusServiceUnavailable)
			return
		}

		// Write the frame to child stdin.
		if err := e.Send(body); err != nil {
			log.Printf("multiplexer team=%s: send to child: %v", teamID, err)
			http.Error(w, "service unavailable", http.StatusServiceUnavailable)
			return
		}
		e.lastUsed = time.Now()

		// Read one newline-terminated response line from child stdout.
		// We pass e.stdout directly; on timeout we close the pipe which
		// unblocks any goroutine blocked on Scan (see readLine).
		respLine, err := readLine(e, 30*time.Second)
		if err != nil {
			log.Printf("multiplexer team=%s: read from child: %v", teamID, err)
			http.Error(w, "service unavailable", http.StatusServiceUnavailable)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintln(w, respLine)
	})
}

// maxBodyBytes caps the inbound MCP frame size.
const maxBodyBytes = 1 * 1024 * 1024 // 1 MiB

// bearerTokenValid returns true when the request carries
// "Authorization: Bearer <serviceKey>" and the comparison is done
// in constant time.
func bearerTokenValid(r *http.Request, serviceKey string) bool {
	auth := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if !strings.HasPrefix(auth, prefix) {
		return false
	}
	provided := auth[len(prefix):]
	return subtle.ConstantTimeCompare([]byte(provided), []byte(serviceKey)) == 1
}

// extractTeamID parses the team_id from a path of the form
// /teams/{team_id}/mcp.
func extractTeamID(path string) string {
	// Trim leading slash.
	p := strings.TrimPrefix(path, "/")
	parts := strings.SplitN(p, "/", 3)
	if len(parts) < 3 || parts[0] != "teams" || parts[2] != "mcp" {
		return ""
	}
	return parts[1]
}

// readLine reads one newline-terminated line from the entry's stdout pipe,
// timing out after d.
//
// On timeout, stdout is closed so that the background scanner goroutine
// unblocks immediately — closing the pipe causes bufio.Scanner.Scan to return
// false, which lets the goroutine exit cleanly. The entry is also marked
// crashed (via closing stdout) so subsequent requests trigger a fresh spawn.
func readLine(e *entry, d time.Duration) (string, error) {
	type result struct {
		line string
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		scanner := bufio.NewScanner(e.stdout)
		if scanner.Scan() {
			ch <- result{line: scanner.Text()}
		} else {
			ch <- result{err: fmt.Errorf("child stdout closed or scan error: %w", scanner.Err())}
		}
	}()

	select {
	case r := <-ch:
		return r.line, r.err
	case <-time.After(d):
		// Close the pipe to unblock the scanner goroutine above.
		// This also causes the child's stdout to EOF, which watchChild will
		// notice when cmd.Wait returns, recording a crash and setting backoff.
		_ = e.stdout.Close()
		return "", fmt.Errorf("timeout reading from child stdout after %s", d)
	}
}

// writeJSONMsg writes a simple {"error":"<msg>"} JSON response.
func writeJSONMsg(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = fmt.Fprintf(w, `{"error":%q}`, msg)
	_, _ = fmt.Fprintln(w)
}

// clientIPStr is a helper that delegates to the tokenbridge clientIP pattern.
func clientIPStr(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.IndexByte(xff, ','); i >= 0 {
			return strings.TrimSpace(xff[:i])
		}
		return strings.TrimSpace(xff)
	}
	if i := strings.LastIndexByte(r.RemoteAddr, ':'); i > 0 {
		return r.RemoteAddr[:i]
	}
	return r.RemoteAddr
}
