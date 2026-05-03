// Command setup is a Tailscale-only HTTP service that provides the
// QwickApps Slack Bridge install page and templates the Tampermonkey
// userscript with deployment-specific configuration.
//
// IMPORTANT: This service must NOT be exposed to the public internet.
// Deploy behind Tailscale only. All endpoints (except /_health) require
// a bearer token set via SETUP_SERVICE_KEY.
//
// Configuration is via environment variables:
//
//	DATABASE_URL       postgres connection string (required; shared with token-bridge)
//	BRIDGE_URL         fully-qualified URL of the deployed token-bridge (required)
//	BRIDGE_HMAC_KEY    HMAC key shared with the token-bridge (required; never logged)
//	SETUP_SERVICE_KEY  bearer token for authenticating setup page access (required)
//	SETUP_PORT         listen port (default 13083)
//	SETUP_HOST         listen host (default 0.0.0.0)
package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/lib/pq"

	"github.com/korotovsky/slack-mcp-server/pkg/setup"
	"github.com/korotovsky/slack-mcp-server/userscript"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("setup: %v", err)
	}
}

func run() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	db, err := sql.Open("postgres", cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer db.Close()

	// Setup is an interactive install-time tool used by one operator at a
	// time on the Tailnet. A small pool is sufficient and avoids holding
	// idle connections against qwickapps-db.
	db.SetMaxOpenConns(2)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(30 * time.Minute)

	pingCtx, pingCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer pingCancel()
	if err := db.PingContext(pingCtx); err != nil {
		return err
	}

	reader := setup.NewDBReader(db)

	handler, err := setup.NewHandler(reader, cfg.ServiceKey, cfg.BridgeURL, cfg.BridgeHMACKey, userscript.Source)
	if err != nil {
		return err
	}

	mux := http.NewServeMux()
	handler.RegisterRoutes(mux)

	srv := &http.Server{
		Addr:              cfg.Host + ":" + cfg.Port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("setup: listening on %s (Tailscale-only — do not expose externally)", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-errCh:
		return err
	case sig := <-sigCh:
		log.Printf("setup: received %s, shutting down", sig)
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}
