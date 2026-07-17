// Package config loads vaultd settings from the environment. Everything the
// server needs to run comes from here so main stays declarative and tests can
// build a Config directly.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
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

	// Admin panel (docs/backend/ADMIN.md). Both must be set to enable the
	// second listener — undeployed means off, fail closed.
	// AdminAddr is the in-container listen address (e.g. ":8081").
	AdminAddr string
	// AdminExternalURL is how the admin's BROWSER reaches the panel through
	// tailscale serve, e.g. https://vault-server.<tailnet>.ts.net:8444 —
	// used for the OAuth redirect URI and the same-origin mutation check.
	AdminExternalURL string

	// Jobs: qBittorrent Web API + worker settings.
	QbitURL      string
	QbitUser     string
	QbitPassword string
	YtdlpBinary  string
	MaxJobs      int
}

// Load reads configuration from the environment, applying defaults and
// validating required fields.
func Load() (*Config, error) {
	c := &Config{
		Addr:             getenv("VAULTD_ADDR", ":8080"),
		DataRoot:         getenv("VAULT_DATA_ROOT", "/srv/vault"),
		OIDCIssuer:       os.Getenv("VAULTD_OIDC_ISSUER"),
		OIDCClientID:     os.Getenv("VAULTD_OIDC_CLIENT_ID"),
		TokenSecret:      os.Getenv("VAULTD_TOKEN_SECRET"),
		AdminAddr:        os.Getenv("VAULTD_ADMIN_ADDR"),
		AdminExternalURL: os.Getenv("VAULTD_ADMIN_EXTERNAL_URL"),
		QbitURL:          getenv("VAULTD_QBIT_URL", "http://qbittorrent:8090"),
		QbitUser:         getenv("VAULTD_QBIT_USER", "admin"),
		QbitPassword:     os.Getenv("VAULTD_QBIT_PASSWORD"),
		YtdlpBinary:      getenv("VAULTD_YTDLP_BIN", "yt-dlp"),
		MaxJobs:          2,
	}
	if v := os.Getenv("VAULTD_MAX_JOBS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			c.MaxJobs = n
		}
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
