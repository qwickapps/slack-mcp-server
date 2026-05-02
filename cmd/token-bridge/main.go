// Command token-bridge is the sidecar HTTP service that ingests xoxc/xoxd
// Slack web client tokens captured by the Tampermonkey userscript (P4),
// encrypts them at rest, and stores them per-workspace for the multiplexer
// (P3) to read when launching upstream mcp-server children.
//
// Configuration is via environment variables:
//
//	DATABASE_URL          postgres connection string (required)
//	TOKEN_ENCRYPTION_KEY  base64-encoded 32-byte AES-256-GCM key (required)
//	BRIDGE_HMAC_KEY       shared secret with the userscript (required)
//	TOKEN_BRIDGE_PORT     listen port (default 13081)
//	TOKEN_BRIDGE_HOST     listen host (default 0.0.0.0)
//	MIGRATIONS_DIR        path to migrations dir (default "migrations")
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

	"github.com/korotovsky/slack-mcp-server/pkg/tokenbridge"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("token-bridge: %v", err)
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

	migCtx, migCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer migCancel()
	if err := tokenbridge.Migrate(migCtx, db, cfg.MigrationsDir); err != nil {
		return err
	}

	cipher, err := tokenbridge.NewCipher(cfg.EncryptionKey)
	if err != nil {
		return err
	}

	store := tokenbridge.NewStore(db)

	mux := http.NewServeMux()
	mux.Handle("/api/tokens/refresh", tokenbridge.RefreshHandler(store, cfg.HMACKey, cipher))
	mux.Handle("/_health", tokenbridge.HealthHandler(store))

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
		log.Printf("token-bridge: listening on %s", srv.Addr)
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
		log.Printf("token-bridge: received %s, shutting down", sig)
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}

type config struct {
	DatabaseURL   string
	EncryptionKey []byte
	HMACKey       []byte
	Host          string
	Port          string
	MigrationsDir string
}

func loadConfig() (*config, error) {
	cfg := &config{
		Host:          getenvDefault("TOKEN_BRIDGE_HOST", "0.0.0.0"),
		Port:          getenvDefault("TOKEN_BRIDGE_PORT", "13081"),
		MigrationsDir: getenvDefault("MIGRATIONS_DIR", "migrations"),
	}

	cfg.DatabaseURL = os.Getenv("DATABASE_URL")
	if cfg.DatabaseURL == "" {
		return nil, errors.New("DATABASE_URL is required")
	}

	encB64 := os.Getenv("TOKEN_ENCRYPTION_KEY")
	if encB64 == "" {
		return nil, errors.New("TOKEN_ENCRYPTION_KEY is required (base64-encoded 32 bytes)")
	}
	key, err := tokenbridge.DecodeKey(encB64)
	if err != nil {
		return nil, err
	}
	cfg.EncryptionKey = key

	hmacKey := os.Getenv("BRIDGE_HMAC_KEY")
	if hmacKey == "" {
		return nil, errors.New("BRIDGE_HMAC_KEY is required")
	}
	cfg.HMACKey = []byte(hmacKey)

	return cfg, nil
}

func getenvDefault(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
