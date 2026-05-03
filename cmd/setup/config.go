package main

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
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
	// Validate at startup so a misconfigured URL fails loudly instead
	// of leaking through into the userscript's @connect directive
	// (where a malformed host silently breaks GM_xmlhttpRequest at the
	// browser-side allowlist check). Strip a trailing slash so
	// BRIDGE_URL + "/api/tokens/refresh" never produces a double slash.
	trimmed, err := validateBridgeURL(cfg.BridgeURL)
	if err != nil {
		return nil, fmt.Errorf("BRIDGE_URL: %w", err)
	}
	cfg.BridgeURL = trimmed

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

// validateBridgeURL parses raw and returns it normalized (trailing slash
// stripped) when it is a well-formed http(s) URL with a non-empty host.
// Returns an error otherwise so the setup service refuses to start with
// a misconfigured BRIDGE_URL — better a fast-fail at boot than a userscript
// that silently can't reach the bridge (the @connect directive only
// allow-lists a parseable host).
func validateBridgeURL(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("not a valid URL: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", fmt.Errorf("scheme must be http or https, got %q", u.Scheme)
	}
	if u.Host == "" {
		return "", errors.New("must include a host")
	}
	return strings.TrimRight(raw, "/"), nil
}
