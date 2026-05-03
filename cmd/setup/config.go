package main

import (
	"errors"
	"os"
)

// config holds all environment-derived configuration for the setup service.
type config struct {
	DatabaseURL   string
	BridgeURL     string
	BridgeHMACKey string
	ServiceKey    string
	Host          string
	Port          string
}

// loadConfig reads configuration from environment variables. All required
// variables must be set; optional variables fall back to defaults.
func loadConfig() (*config, error) {
	cfg := &config{
		Host: getenvDefault("SETUP_HOST", "0.0.0.0"),
		Port: getenvDefault("SETUP_PORT", "13083"),
	}

	cfg.DatabaseURL = os.Getenv("DATABASE_URL")
	if cfg.DatabaseURL == "" {
		return nil, errors.New("DATABASE_URL is required")
	}

	cfg.BridgeURL = os.Getenv("BRIDGE_URL")
	if cfg.BridgeURL == "" {
		return nil, errors.New("BRIDGE_URL is required")
	}

	cfg.BridgeHMACKey = os.Getenv("BRIDGE_HMAC_KEY")
	if cfg.BridgeHMACKey == "" {
		return nil, errors.New("BRIDGE_HMAC_KEY is required")
	}

	cfg.ServiceKey = os.Getenv("SETUP_SERVICE_KEY")
	if cfg.ServiceKey == "" {
		return nil, errors.New("SETUP_SERVICE_KEY is required")
	}

	return cfg, nil
}

// getenvDefault returns the value of the named environment variable, or def
// when the variable is unset or empty.
func getenvDefault(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
