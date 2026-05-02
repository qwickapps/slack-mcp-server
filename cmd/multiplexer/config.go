package main

import (
	"errors"
	"os"
	"time"

	"github.com/korotovsky/slack-mcp-server/pkg/tokenbridge"
)

// config holds the runtime configuration for the multiplexer service.
type config struct {
	DatabaseURL   string
	EncryptionKey []byte
	ServiceKey    string
	Host          string
	Port          string
	IdleTimeout   time.Duration
	PollInterval  time.Duration
	MCPServerBin  string
}

// loadConfig reads configuration from environment variables.
// All required variables must be non-empty; optional variables fall back
// to the defaults documented in the env var table.
func loadConfig() (*config, error) {
	cfg := &config{
		Host:         getenvDefault("MULTIPLEXER_HOST", "0.0.0.0"),
		Port:         getenvDefault("MULTIPLEXER_PORT", "13082"),
		MCPServerBin: getenvDefault("MCP_SERVER_BIN", "/usr/local/bin/mcp-server"),
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

	cfg.ServiceKey = os.Getenv("MULTIPLEXER_SERVICE_KEY")
	if cfg.ServiceKey == "" {
		return nil, errors.New("MULTIPLEXER_SERVICE_KEY is required")
	}

	cfg.IdleTimeout, err = parseDurationEnv("MULTIPLEXER_IDLE_TIMEOUT", 10*time.Minute)
	if err != nil {
		return nil, err
	}

	cfg.PollInterval, err = parseDurationEnv("MULTIPLEXER_POLL_INTERVAL", 30*time.Second)
	if err != nil {
		return nil, err
	}

	return cfg, nil
}

// parseDurationEnv reads a duration from an environment variable.
// If the variable is unset or empty, def is returned. If it is set but
// cannot be parsed, an error is returned.
func parseDurationEnv(k string, def time.Duration) (time.Duration, error) {
	v := os.Getenv(k)
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return 0, errors.New(k + ": " + err.Error())
	}
	return d, nil
}

// getenvDefault returns the value of env var k, or def when unset/empty.
func getenvDefault(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
