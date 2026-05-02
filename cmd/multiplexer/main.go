// Command multiplexer is an HTTP service that fronts per-team upstream
// mcp-server child processes. Each team's child is lazily spawned on the
// first request using decrypted xoxc/xoxd credentials from the token-bridge
// database.
//
// Configuration is via environment variables:
//
//	DATABASE_URL              postgres connection string (required; shared with token-bridge)
//	TOKEN_ENCRYPTION_KEY      base64-encoded 32-byte AES-256-GCM key (required)
//	MULTIPLEXER_SERVICE_KEY   shared bearer token for callers (required)
//	MULTIPLEXER_PORT          listen port (default 13082)
//	MULTIPLEXER_HOST          listen host (default 0.0.0.0)
//	MULTIPLEXER_IDLE_TIMEOUT  child idle timeout (default 10m)
//	MULTIPLEXER_POLL_INTERVAL token-refresh poll interval (default 30s)
//	MCP_SERVER_BIN            path to upstream binary (default /usr/local/bin/mcp-server)
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

	"github.com/korotovsky/slack-mcp-server/pkg/multiplexer"
	"github.com/korotovsky/slack-mcp-server/pkg/tokenbridge"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("multiplexer: %v", err)
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

	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(30 * time.Minute)

	pingCtx, pingCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer pingCancel()
	if err := db.PingContext(pingCtx); err != nil {
		return err
	}

	cipher, err := tokenbridge.NewCipher(cfg.EncryptionKey)
	if err != nil {
		return err
	}

	reader := multiplexer.NewDBReader(db)
	reg := multiplexer.NewRegistry(reader, multiplexer.RegistryConfig{
		MCPServerBin:    cfg.MCPServerBin,
		IdleTimeout:     cfg.IdleTimeout,
		Cipher:          cipher,
	})

	// Start background goroutines. They stop when rootCtx is cancelled.
	rootCtx, rootCancel := context.WithCancel(context.Background())
	defer rootCancel()

	reg.RunIdleSweeper(rootCtx)
	reg.RunRefreshPoller(rootCtx, cfg.PollInterval)

	mux := http.NewServeMux()
	mux.Handle("/teams/", multiplexer.ProxyHandler(reg, cfg.ServiceKey))
	mux.Handle("/_health", multiplexer.HealthHandler(reader))
	mux.Handle("/_status", multiplexer.StatusHandler(reg, cfg.ServiceKey))

	srv := &http.Server{
		Addr:              cfg.Host + ":" + cfg.Port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       35 * time.Second,
		WriteTimeout:      35 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("multiplexer: listening on %s", srv.Addr)
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
		log.Printf("multiplexer: received %s, shutting down", sig)
	}

	// Stop background goroutines before shutting down children.
	rootCancel()

	// Graceful HTTP shutdown (10 seconds).
	shutCtx, shutCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutCancel()
	if err := srv.Shutdown(shutCtx); err != nil {
		log.Printf("multiplexer: http shutdown: %v", err)
	}

	// Terminate all child processes.
	reg.ShutdownAll()
	return nil
}
