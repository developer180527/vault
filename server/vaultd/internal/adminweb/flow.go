package adminweb

import (
	"context"
	"fmt"
	"sync"

	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"

	"github.com/developer180527/vault/vaultd/internal/auth"
)

// OAuthFlow abstracts the browser OIDC dance (authorize URL, code exchange,
// id_token verification) so tests can fake the IdP without HTTP.
type OAuthFlow interface {
	// AuthCodeURL builds the Pocket ID authorize redirect carrying state,
	// nonce, and the PKCE S256 challenge for [verifier].
	AuthCodeURL(ctx context.Context, state, nonce, verifier string) (string, error)

	// Exchange trades the callback code (+ PKCE verifier) for a raw id_token.
	Exchange(ctx context.Context, code, verifier string) (string, error)

	// VerifyIDToken validates the id_token (issuer, audience, signature,
	// expiry) and returns the identity plus the token's nonce claim.
	VerifyIDToken(ctx context.Context, raw string) (*auth.Identity, string, error)
}

// oidcFlow is the real implementation against Pocket ID. The provider is
// discovered LAZILY on first use — Pocket ID being down when vaultd boots
// must not permanently disable the panel (a lesson from the app-path
// verifier, which is built once at startup).
type oidcFlow struct {
	issuer      string
	clientID    string
	redirectURL string

	mu       sync.Mutex
	provider *oidc.Provider
}

// NewOIDCFlow prepares the lazy flow. [redirectURL] is the externally
// reachable callback, e.g. https://host:8444/oauth/callback.
func NewOIDCFlow(issuer, clientID, redirectURL string) OAuthFlow {
	return &oidcFlow{issuer: issuer, clientID: clientID, redirectURL: redirectURL}
}

func (f *oidcFlow) prov(ctx context.Context) (*oidc.Provider, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.provider != nil {
		return f.provider, nil
	}
	p, err := oidc.NewProvider(ctx, f.issuer)
	if err != nil {
		return nil, fmt.Errorf("oidc discovery %s: %w", f.issuer, err)
	}
	f.provider = p
	return p, nil
}

func (f *oidcFlow) conf(p *oidc.Provider) *oauth2.Config {
	return &oauth2.Config{
		ClientID:    f.clientID, // public client: PKCE, no secret
		Endpoint:    p.Endpoint(),
		RedirectURL: f.redirectURL,
		Scopes:      []string{oidc.ScopeOpenID, "profile", "email"},
	}
}

func (f *oidcFlow) AuthCodeURL(ctx context.Context, state, nonce, verifier string) (string, error) {
	p, err := f.prov(ctx)
	if err != nil {
		return "", err
	}
	return f.conf(p).AuthCodeURL(state,
		oauth2.S256ChallengeOption(verifier),
		oauth2.SetAuthURLParam("nonce", nonce),
	), nil
}

func (f *oidcFlow) Exchange(ctx context.Context, code, verifier string) (string, error) {
	p, err := f.prov(ctx)
	if err != nil {
		return "", err
	}
	tok, err := f.conf(p).Exchange(ctx, code, oauth2.VerifierOption(verifier))
	if err != nil {
		return "", fmt.Errorf("code exchange: %w", err)
	}
	raw, _ := tok.Extra("id_token").(string)
	if raw == "" {
		return "", fmt.Errorf("token response carried no id_token")
	}
	return raw, nil
}

func (f *oidcFlow) VerifyIDToken(ctx context.Context, raw string) (*auth.Identity, string, error) {
	p, err := f.prov(ctx)
	if err != nil {
		return nil, "", err
	}
	tok, err := p.Verifier(&oidc.Config{ClientID: f.clientID}).Verify(ctx, raw)
	if err != nil {
		return nil, "", err
	}
	var claims struct {
		Email    string `json:"email"`
		Name     string `json:"name"`
		Username string `json:"preferred_username"`
		Nonce    string `json:"nonce"`
	}
	if err := tok.Claims(&claims); err != nil {
		return nil, "", err
	}
	return &auth.Identity{
		Issuer:   f.issuer,
		Subject:  tok.Subject,
		Email:    claims.Email,
		Name:     claims.Name,
		Username: claims.Username,
	}, claims.Nonce, nil
}
