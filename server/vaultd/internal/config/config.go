// Package config loads vaultd settings from the environment. Everything the
// server needs to run comes from here so main stays declarative and tests can
// build a Config directly.
package config

import (
	"fmt"
	"os"
	"path/filepath"
)

// Config is the fully-resolved runtime configuration.
type Config struct {
	// Addr is the host:port the HTTP server listens on (Caddy proxies to it).
	Addr string

	// DataRoot is /srv/vault — user libraries + system state live under it.
	DataRoot string

	// DBPath is the SQLite file (WAL). Derived from DataRoot by default.
	DBPath string

	// OIDCIssuer is Pocket ID's issuer URL, e.g.
	// https://vault-server.<tailnet>.ts.net:9443 — used to fetch JWKS and to
	// validate the `iss` claim.
	OIDCIssuer string

	// OIDCClientID is the client id vaultd is registered as in Pocket ID.
	OIDCClientID string

	// TokenSecret signs vaultd's own access tokens (device sessions). Must be
	// stable across restarts or every device is logged out.
	TokenSecret string
}

// Load reads configuration from the environment, applying defaults and
// validating required fields.
func Load() (*Config, error) {
	c := &Config{
		Addr:         getenv("VAULTD_ADDR", ":8080"),
		DataRoot:     getenv("VAULT_DATA_ROOT", "/srv/vault"),
		OIDCIssuer:   os.Getenv("VAULTD_OIDC_ISSUER"),
		OIDCClientID: os.Getenv("VAULTD_OIDC_CLIENT_ID"),
		TokenSecret:  os.Getenv("VAULTD_TOKEN_SECRET"),
	}
	if c.DBPath == "" {
		c.DBPath = filepath.Join(c.DataRoot, "system", "db", "vault.db")
	}

	// OIDC + token secret are required for auth, but the skeleton (health +
	// migrations) must run without them so M2 can be brought up incrementally.
	// Handlers that need them check at call time; see auth package.
	if c.DataRoot == "" {
		return nil, fmt.Errorf("VAULT_DATA_ROOT must be set")
	}
	return c, nil
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
