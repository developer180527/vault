// Command vaultd is the Vault gateway server. This entrypoint stays
// declarative: load config, open the store (runs migrations), build the HTTP
// handler, serve. Everything else lives in internal packages.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/developer180527/vault/vaultd/internal/auth"
	"github.com/developer180527/vault/vaultd/internal/config"
	"github.com/developer180527/vault/vaultd/internal/httpapi"
	"github.com/developer180527/vault/vaultd/internal/store"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := config.Load()
	if err != nil {
		log.Error("config", "err", err)
		os.Exit(1)
	}

	ctx := context.Background()
	st, err := store.Open(ctx, cfg.DBPath)
	if err != nil {
		log.Error("store open", "err", err, "path", cfg.DBPath)
		os.Exit(1)
	}
	defer st.Close()
	log.Info("store ready", "path", cfg.DBPath)

	// OIDC verification against Pocket ID. Failure is non-fatal so the rest
	// of the server (health, later read paths) stays up, but auth endpoints
	// will refuse until the issuer is reachable.
	var verifier auth.Verifier
	if cfg.OIDCIssuer != "" {
		v, err := auth.NewOIDCVerifier(ctx, cfg.OIDCIssuer, cfg.OIDCClientID)
		if err != nil {
			log.Warn("OIDC verifier unavailable — auth disabled", "err", err)
		} else {
			verifier = v
			log.Info("OIDC ready", "issuer", cfg.OIDCIssuer)
		}
	} else {
		log.Warn("VAULTD_OIDC_ISSUER not set — auth disabled")
	}

	// One-time bootstrap: while no users exist, print a setup code the first
	// admin presents alongside their Pocket ID login.
	setupCode := ""
	if n, err := st.Read().CountUsers(ctx); err == nil && n == 0 {
		b := make([]byte, 4)
		_, _ = rand.Read(b)
		setupCode = hex.EncodeToString(b)
		log.Warn("NO USERS YET — one-time setup code (POST /v1/setup)",
			"code", setupCode)
	}

	srv := &http.Server{
		Addr: cfg.Addr,
		Handler: httpapi.New(httpapi.Options{
			Log:       log,
			Store:     st,
			Verifier:  verifier,
			SetupCode: setupCode,
		}),
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Graceful shutdown on SIGINT/SIGTERM.
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		log.Info("shutting down")
		shutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutCtx)
	}()

	log.Info("vaultd listening", "addr", cfg.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("serve", "err", err)
		os.Exit(1)
	}
}
