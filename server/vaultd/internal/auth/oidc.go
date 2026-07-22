package auth

import (
	"context"
	"fmt"

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
