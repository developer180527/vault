package auth

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

// Identity is what vaultd needs from a verified ID token.
type Identity struct {
	Issuer        string
	Subject       string
	Email         string
	EmailVerified bool
	Name          string
	Username      string // preferred_username claim, if present
}

// Verifier validates a raw OIDC ID token and extracts the identity.
// An interface so tests can substitute a fake IdP.
type Verifier interface {
	Verify(ctx context.Context, rawIDToken string) (*Identity, error)
}

type oidcVerifier struct {
	issuer   string
	verifier *oidc.IDTokenVerifier
}

// NewOIDCVerifier discovers the issuer (Pocket ID) and prepares JWT
// verification against its JWKS. Fails if the issuer is unreachable — vaultd
// should start anyway and report auth as unavailable, so call lazily.
func NewOIDCVerifier(ctx context.Context, issuer, clientID string) (Verifier, error) {
	if issuer == "" || clientID == "" {
		return nil, fmt.Errorf("OIDC issuer/client id not configured")
	}
	provider, err := oidc.NewProvider(ctx, issuer)
	if err != nil {
		return nil, fmt.Errorf("oidc discovery %s: %w", issuer, err)
	}
	return &oidcVerifier{
		issuer:   issuer,
		verifier: provider.Verifier(&oidc.Config{ClientID: clientID}),
	}, nil
}

// RetryingVerifier is a Verifier that starts EMPTY and self-heals: OIDC
// discovery is retried in the background until the issuer becomes reachable,
// at which point real verification takes over. This is why a cold power-on no
// longer permanently disables auth — vaultd routinely boots before Tailscale/
// Pocket ID are up (DNS for the tailnet name isn't resolvable yet), and the
// old code gave up after one failed discovery.
type RetryingVerifier struct {
	mu    sync.RWMutex
	inner Verifier // nil until discovery succeeds
}

func (r *RetryingVerifier) set(v Verifier) {
	r.mu.Lock()
	r.inner = v
	r.mu.Unlock()
}

// Ready reports whether discovery has completed (auth is live).
func (r *RetryingVerifier) Ready() bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.inner != nil
}

func (r *RetryingVerifier) Verify(ctx context.Context, raw string) (*Identity, error) {
	r.mu.RLock()
	v := r.inner
	r.mu.RUnlock()
	if v == nil {
		return nil, errors.New(
			"auth not ready yet — the identity provider was unreachable at startup; retrying")
	}
	return v.Verify(ctx, raw)
}

// StartOIDCDiscovery returns a verifier immediately and keeps retrying
// discovery in the background (exponential backoff, capped) until it succeeds
// or [ctx] is cancelled. Verification is unavailable (returns a clear error)
// until the first success, then works for the life of the process.
func StartOIDCDiscovery(ctx context.Context, issuer, clientID string, log *slog.Logger) *RetryingVerifier {
	rv := &RetryingVerifier{}
	go func() {
		backoff := time.Second
		const maxBackoff = 30 * time.Second
		for {
			v, err := NewOIDCVerifier(ctx, issuer, clientID)
			if err == nil {
				rv.set(v)
				log.Info("OIDC ready", "issuer", issuer)
				return
			}
			log.Warn("OIDC discovery failed — retrying",
				"err", err, "retry_in", backoff.String())
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			if backoff *= 2; backoff > maxBackoff {
				backoff = maxBackoff
			}
		}
	}()
	return rv
}

func (v *oidcVerifier) Verify(ctx context.Context, raw string) (*Identity, error) {
	tok, err := v.verifier.Verify(ctx, raw)
	if err != nil {
		return nil, err
	}
	var claims struct {
		Email         string `json:"email"`
		EmailVerified *bool  `json:"email_verified"`
		Name          string `json:"name"`
		Username      string `json:"preferred_username"`
	}
	if err := tok.Claims(&claims); err != nil {
		return nil, err
	}
	return &Identity{
		Issuer:  v.issuer,
		Subject: tok.Subject,
		Email:   claims.Email,
		// Absent claim → treated as verified (our IdP is admin-controlled and
		// may omit it); only an EXPLICIT false marks the email unverified.
		EmailVerified: claims.EmailVerified == nil || *claims.EmailVerified,
		Name:          claims.Name,
		Username:      claims.Username,
	}, nil
}
