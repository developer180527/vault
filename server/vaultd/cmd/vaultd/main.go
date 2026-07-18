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
	"path/filepath"
	"syscall"
	"time"

	"github.com/developer180527/vault/vaultd/internal/adminweb"
	"github.com/developer180527/vault/vaultd/internal/auth"
	"github.com/developer180527/vault/vaultd/internal/config"
	"github.com/developer180527/vault/vaultd/internal/httpapi"
	"github.com/developer180527/vault/vaultd/internal/jobs"
	"github.com/developer180527/vault/vaultd/internal/music"
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

	// Background-work engine: torrent (qBittorrent) + URL (yt-dlp) runners,
	// unified scheduler, SSE hub. Staging dirs live under DataRoot.
	staging := filepath.Join(cfg.DataRoot, "staging")
	engine := jobs.New(log, st, cfg.DataRoot, cfg.MaxJobs, map[string]jobs.Runner{
		store.JobKindTorrent: &jobs.TorrentRunner{
			Client:   jobs.NewQbitClient(cfg.QbitURL, cfg.QbitUser, cfg.QbitPassword),
			SavePath: filepath.Join(staging, "torrents"),
		},
		store.JobKindDownload: &jobs.YtdlpRunner{
			Binary:      cfg.YtdlpBinary,
			StagingRoot: filepath.Join(staging, "ytdlp"),
		},
	})
	engine.Start()
	defer engine.Stop()
	log.Info("jobs engine started", "maxConcurrent", cfg.MaxJobs)

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

	// Stream-URL signing key: generated once, lives with the DB under
	// system/. Signed URLs let playback outlive the 15-minute bearer.
	signer, err := auth.LoadOrCreateStreamKey(
		filepath.Join(cfg.DataRoot, "system", "stream_signing_key"))
	if err != nil {
		log.Warn("stream signing unavailable — streams stay bearer-only", "err", err)
	}

	srv := &http.Server{
		Addr: cfg.Addr,
		Handler: httpapi.New(httpapi.Options{
			Log:          log,
			Store:        st,
			Verifier:     verifier,
			SetupCode:    setupCode,
			OIDCIssuer:   cfg.OIDCIssuer,
			OIDCClientID: cfg.OIDCClientID,
			DataRoot:     cfg.DataRoot,
			Jobs:         engine,
			Signer:       signer,
		}),
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Admin panel: a SEPARATE listener so the member surface can never route
	// to an admin handler; enabled only when both knobs are set
	// (docs/backend/ADMIN.md). Off = fail closed.
	var adminSrv *http.Server
	if cfg.AdminAddr != "" && cfg.AdminExternalURL != "" {
		handler, err := adminweb.New(adminweb.Options{
			Log:   log,
			Store: st,
			Music: &music.Service{
				DataRoot: cfg.DataRoot, Store: st, Log: log},
			ExternalURL: cfg.AdminExternalURL,
			Flow: adminweb.NewOIDCFlow(cfg.OIDCIssuer, cfg.OIDCClientID,
				cfg.AdminExternalURL+"/oauth/callback"),
		})
		if err != nil {
			log.Error("admin panel", "err", err)
			os.Exit(1)
		}
		adminSrv = &http.Server{
			Addr:              cfg.AdminAddr,
			Handler:           handler,
			ReadHeaderTimeout: 10 * time.Second,
		}
		go func() {
			log.Info("admin panel listening",
				"addr", cfg.AdminAddr, "external", cfg.AdminExternalURL)
			if err := adminSrv.ListenAndServe(); err != nil &&
				!errors.Is(err, http.ErrServerClosed) {
				log.Error("admin serve", "err", err)
			}
		}()
	} else {
		log.Info("admin panel disabled (set VAULTD_ADMIN_ADDR + VAULTD_ADMIN_EXTERNAL_URL)")
	}

	// Graceful shutdown on SIGINT/SIGTERM.
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		log.Info("shutting down")
		shutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if adminSrv != nil {
			_ = adminSrv.Shutdown(shutCtx)
		}
		_ = srv.Shutdown(shutCtx)
	}()

	log.Info("vaultd listening", "addr", cfg.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("serve", "err", err)
		os.Exit(1)
	}
}
