package setup

import (
	"bytes"
	"context"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"html/template"
	"log"
	"net/http"
	"strings"
	"time"
)

//go:embed templates/index.html
var templateFS embed.FS

// Handler holds the dependencies for the setup HTTP endpoints.
type Handler struct {
	reader             WorkspaceStatusReader
	serviceKey         string
	bridgeURL          string
	hmacKey            string
	tmpl               *template.Template
	userscriptTemplate string
}

// NewHandler constructs a Handler. It parses the embedded HTML template
// at construction time so any template syntax error fails fast.
// userscriptSrc is the raw content of the .user.js file (with placeholders);
// it is passed in by the caller (cmd/setup) which embeds it directly.
func NewHandler(reader WorkspaceStatusReader, serviceKey, bridgeURL, hmacKey, userscriptSrc string) (*Handler, error) {
	tmplData, err := templateFS.ReadFile("templates/index.html")
	if err != nil {
		return nil, err
	}
	tmpl, err := template.New("index").Parse(string(tmplData))
	if err != nil {
		return nil, err
	}
	return &Handler{
		reader:             reader,
		serviceKey:         serviceKey,
		bridgeURL:          bridgeURL,
		hmacKey:            hmacKey,
		tmpl:               tmpl,
		userscriptTemplate: userscriptSrc,
	}, nil
}

// RegisterRoutes wires the handler's endpoints onto mux.
func (h *Handler) RegisterRoutes(mux *http.ServeMux) {
	mux.Handle("/", h.auth(h.handleIndex()))
	mux.Handle("/userscript.user.js", h.auth(h.handleUserscript()))
	mux.Handle("/_health", h.handleHealth())
}

// auth wraps next with bearer token authentication. The comparison is
// constant-time. Unauthenticated requests receive 401.
func (h *Handler) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !bearerValid(r, h.serviceKey) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// handleIndex returns an http.Handler that renders the workspace status page.
func (h *Handler) handleIndex() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		workspaces, err := h.reader.ListWorkspaces(ctx)
		if err != nil {
			log.Printf("setup: list workspaces: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		type row struct {
			TeamID          string
			TeamName        string
			LastRefreshedAt time.Time
			Fresh           bool
		}

		now := time.Now().UTC()
		rows := make([]row, len(workspaces))
		for i, ws := range workspaces {
			rows[i] = row{
				TeamID:          ws.TeamID,
				TeamName:        ws.TeamName,
				LastRefreshedAt: ws.LastRefreshedAt.UTC(),
				Fresh:           now.Sub(ws.LastRefreshedAt) <= time.Hour,
			}
		}

		data := struct {
			Workspaces []row
		}{Workspaces: rows}

		var buf bytes.Buffer
		if err := h.tmpl.Execute(&buf, data); err != nil {
			log.Printf("setup: render index: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(buf.Bytes())
	})
}

// handleUserscript returns an http.Handler that serves the userscript
// with __BRIDGE_URL__ and __BRIDGE_HMAC_KEY__ substituted.
func (h *Handler) handleUserscript() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		// Derive the host portion from BRIDGE_URL for the @connect directive.
		bridgeHost := bridgeHostFromURL(h.bridgeURL)

		script := strings.ReplaceAll(h.userscriptTemplate, "__BRIDGE_URL__", h.bridgeURL)
		script = strings.ReplaceAll(script, "__BRIDGE_HMAC_KEY__", h.hmacKey)
		// Replace the @connect placeholder too, which uses a separate token.
		script = strings.ReplaceAll(script, "__BRIDGE_HOST__", bridgeHost)

		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.Header().Set("Content-Disposition", `attachment; filename="qwickapps-slack-bridge.user.js"`)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(script))
	})
}

// handleHealth returns an http.Handler for GET /_health (no auth required).
func (h *Handler) handleHealth() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()

		type healthResp struct {
			Status string `json:"status"`
		}

		if err := h.reader.Ping(ctx); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_ = json.NewEncoder(w).Encode(healthResp{Status: "unhealthy"})
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(healthResp{Status: "ok"})
	})
}

// bearerValid returns true when the request carries a valid
// "Authorization: Bearer <key>" header, compared in constant time.
func bearerValid(r *http.Request, key string) bool {
	auth := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if !strings.HasPrefix(auth, prefix) {
		return false
	}
	provided := auth[len(prefix):]
	return subtle.ConstantTimeCompare([]byte(provided), []byte(key)) == 1
}

// bridgeHostFromURL extracts the host (with optional port) from a URL
// string, for use in the Tampermonkey @connect directive.
// E.g. "https://slack-bridge.dev.qwickapps.com" -> "slack-bridge.dev.qwickapps.com"
func bridgeHostFromURL(rawURL string) string {
	s := rawURL
	if i := strings.Index(s, "://"); i >= 0 {
		s = s[i+3:]
	}
	// Strip path/query/fragment.
	if i := strings.IndexAny(s, "/?#"); i >= 0 {
		s = s[:i]
	}
	return s
}
