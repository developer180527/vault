package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/developer180527/vault/vaultd/internal/auth"
)

func TestAdminSessions_Lifecycle(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	admin, err := s.Write().CreateUser(ctx, "venu", "venu@example.com", "", "admin", "https://idp", "sub-venu")
	if err != nil {
		t.Fatal(err)
	}
	_, hash := auth.NewToken()
	if err := s.Write().CreateAdminSession(ctx, admin.ID, hash, now.Add(12*time.Hour)); err != nil {
		t.Fatalf("create session: %v", err)
	}

	// Live token resolves the user row.
	u, err := s.Read().AdminSessionUser(ctx, hash, now)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if u.ID != admin.ID || u.Role != "admin" {
		t.Fatalf("user = %+v", u)
	}

	// Unknown hash fails closed.
	if _, err := s.Read().AdminSessionUser(ctx, auth.HashToken("nope"), now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown err = %v, want ErrNotFound", err)
	}

	// Exactly at expiry the session is dead (strict >).
	if _, err := s.Read().AdminSessionUser(ctx, hash, now.Add(12*time.Hour)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("at-expiry err = %v, want ErrNotFound", err)
	}

	// Logout revokes; double logout is a no-op.
	if err := s.Write().DeleteAdminSession(ctx, hash); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Read().AdminSessionUser(ctx, hash, now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("post-logout err = %v, want ErrNotFound", err)
	}
	if err := s.Write().DeleteAdminSession(ctx, hash); err != nil {
		t.Fatalf("idempotent logout: %v", err)
	}

	// Prune drops only expired rows.
	_, h2 := auth.NewToken()
	_, h3 := auth.NewToken()
	_ = s.Write().CreateAdminSession(ctx, admin.ID, h2, now.Add(-time.Minute))
	_ = s.Write().CreateAdminSession(ctx, admin.ID, h3, now.Add(time.Hour))
	if err := s.Write().PruneAdminSessions(ctx, now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Read().AdminSessionUser(ctx, h3, now); err != nil {
		t.Fatalf("live session pruned: %v", err)
	}
	if _, err := s.Read().AdminSessionUser(ctx, h2, now.Add(-2*time.Minute)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expired session survived prune")
	}
}
