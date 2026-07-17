package store

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/developer180527/vault/vaultd/internal/auth"
)

func openTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(context.Background(), filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

// seedDevice creates an active user + device, returning ids and token hashes.
func seedDevice(t *testing.T, s *Store, username string, accessExpires time.Time) (userID, deviceID, accessHash, refreshHash string) {
	t.Helper()
	ctx := context.Background()
	u, err := s.Write().CreateUser(ctx, username, username+"@example.com", "", "member", "https://idp", "sub-"+username)
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	_, accessHash = auth.NewToken()
	_, refreshHash = auth.NewToken()
	d, err := s.Write().CreateDevice(ctx, u.ID, "phone", "ios", accessHash, accessExpires, refreshHash)
	if err != nil {
		t.Fatalf("create device: %v", err)
	}
	return u.ID, d.ID, accessHash, refreshHash
}

func TestPrincipalByAccessHash_ExpiryAndUserStatus(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	now := time.Now()
	userID, deviceID, accessHash, _ := seedDevice(t, s, "venu", now.Add(15*time.Minute))

	// Live token resolves the full principal.
	p, err := s.Read().PrincipalByAccessHash(ctx, accessHash, now)
	if err != nil {
		t.Fatalf("live token: %v", err)
	}
	if p.UserID != userID || p.DeviceID != deviceID || p.Username != "venu" || p.Role != "member" {
		t.Fatalf("principal = %+v", p)
	}

	// Unknown hash fails closed.
	if _, err := s.Read().PrincipalByAccessHash(ctx, auth.HashToken("nope"), now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown hash err = %v, want ErrNotFound", err)
	}

	// Exactly at/after expiry the token is dead (boundary uses strict >).
	at := now.Add(15 * time.Minute)
	if _, err := s.Read().PrincipalByAccessHash(ctx, accessHash, at); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expired token err = %v, want ErrNotFound", err)
	}

	// SECURITY INVARIANT: disabling a user kills their live access tokens
	// immediately — no waiting for expiry.
	if err := s.Write().SetUserStatus(ctx, userID, "disabled"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Read().PrincipalByAccessHash(ctx, accessHash, now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("disabled-user token err = %v, want ErrNotFound", err)
	}
}

func TestMatchRefresh_DisabledUserFailsClosed(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	userID, deviceID, _, refreshHash := seedDevice(t, s, "maya", time.Now().Add(time.Hour))

	m, err := s.Read().MatchRefresh(ctx, refreshHash)
	if err != nil {
		t.Fatalf("match: %v", err)
	}
	if !m.Current || m.DeviceID != deviceID || m.UserID != userID {
		t.Fatalf("match = %+v", m)
	}

	if _, err := s.Read().MatchRefresh(ctx, auth.HashToken("nope")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown refresh err = %v, want ErrNotFound", err)
	}

	// SECURITY INVARIANT: a disabled user can't refresh either.
	if err := s.Write().SetUserStatus(ctx, userID, "disabled"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Read().MatchRefresh(ctx, refreshHash); !errors.Is(err, ErrNotFound) {
		t.Fatalf("disabled-user refresh err = %v, want ErrNotFound", err)
	}
}

func TestRotateTokens_GraceWindowDoesNotExtend(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	_, deviceID, _, refresh0 := seedDevice(t, s, "venu", time.Now().Add(time.Hour))

	// Normal rotation at t1: refresh0 becomes prev, refresh1 current.
	t1 := time.Now().Truncate(time.Second)
	_, access1 := auth.NewToken()
	_, refresh1 := auth.NewToken()
	if err := s.Write().RotateTokens(ctx, deviceID, true, access1, t1.Add(auth.AccessTTL), refresh1, t1); err != nil {
		t.Fatal(err)
	}

	m0, err := s.Read().MatchRefresh(ctx, refresh0)
	if err != nil {
		t.Fatalf("prev token should still match: %v", err)
	}
	if m0.Current {
		t.Fatal("rotated-out token still reported as current")
	}
	if !m0.RotatedAt.Equal(t1) {
		t.Fatalf("rotated_at = %v, want %v", m0.RotatedAt, t1)
	}

	// Grace replay at t2 (fromCurrent=false): a NEW pair is issued, but
	// prev_hash and rotated_at must NOT move — otherwise an attacker could
	// keep the stolen token alive forever by replaying inside each window.
	t2 := t1.Add(30 * time.Second)
	_, access2 := auth.NewToken()
	_, refresh2 := auth.NewToken()
	if err := s.Write().RotateTokens(ctx, deviceID, false, access2, t2.Add(auth.AccessTTL), refresh2, t2); err != nil {
		t.Fatal(err)
	}

	m0b, err := s.Read().MatchRefresh(ctx, refresh0)
	if err != nil {
		t.Fatalf("prev token gone after grace replay: %v", err)
	}
	if !m0b.RotatedAt.Equal(t1) {
		t.Fatalf("grace replay EXTENDED the window: rotated_at %v → %v", t1, m0b.RotatedAt)
	}

	// The newest refresh is current; the superseded refresh1 (replaced by the
	// grace path without becoming prev) is dead.
	if m2, err := s.Read().MatchRefresh(ctx, refresh2); err != nil || !m2.Current {
		t.Fatalf("newest refresh: m=%+v err=%v", m2, err)
	}
	if _, err := s.Read().MatchRefresh(ctx, refresh1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("superseded refresh err = %v, want ErrNotFound", err)
	}
}

func TestRevokeDeviceKillsBothTokens(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	_, deviceID, accessHash, refreshHash := seedDevice(t, s, "venu", time.Now().Add(time.Hour))

	if err := s.Write().RevokeDevice(ctx, deviceID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Read().PrincipalByAccessHash(ctx, accessHash, time.Now()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("access after revoke err = %v, want ErrNotFound", err)
	}
	if _, err := s.Read().MatchRefresh(ctx, refreshHash); !errors.Is(err, ErrNotFound) {
		t.Fatalf("refresh after revoke err = %v, want ErrNotFound", err)
	}
	// Double revoke reports not-found rather than silently succeeding.
	if err := s.Write().RevokeDevice(ctx, deviceID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("double revoke err = %v, want ErrNotFound", err)
	}
}

func TestInviteBindingIsOneShot(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()

	// Invited user: email only, no OIDC identity yet.
	u, err := s.Write().CreateUser(ctx, "maya", "maya@example.com", "", "member", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Read().UserByOIDC(ctx, "https://idp", "sub-1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unbound identity resolved: %v", err)
	}
	pending, err := s.Read().PendingUserByEmail(ctx, "maya@example.com")
	if err != nil || pending.ID != u.ID {
		t.Fatalf("pending lookup: %+v, %v", pending, err)
	}

	// First login binds…
	if err := s.Write().BindOIDC(ctx, u.ID, "https://idp", "sub-1"); err != nil {
		t.Fatal(err)
	}
	bound, err := s.Read().UserByOIDC(ctx, "https://idp", "sub-1")
	if err != nil || bound.ID != u.ID {
		t.Fatalf("bound lookup: %v", err)
	}

	// …and binding is permanent: no rebinding to a different identity, and the
	// user no longer matches as a pending invite (else a second person with
	// the same email could hijack the account).
	if err := s.Write().BindOIDC(ctx, u.ID, "https://evil", "sub-2"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("rebind err = %v, want ErrNotFound", err)
	}
	if _, err := s.Read().PendingUserByEmail(ctx, "maya@example.com"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("bound user still pending: %v", err)
	}
}

func TestCreateUserUniqueness(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	if _, err := s.Write().CreateUser(ctx, "venu", "venu@example.com", "", "admin", "https://idp", "sub-1"); err != nil {
		t.Fatal(err)
	}
	// Duplicate username.
	if _, err := s.Write().CreateUser(ctx, "venu", "other@example.com", "", "member", "", ""); err == nil {
		t.Fatal("duplicate username accepted")
	}
	// Duplicate OIDC identity.
	if _, err := s.Write().CreateUser(ctx, "venu2", "venu2@example.com", "", "member", "https://idp", "sub-1"); err == nil {
		t.Fatal("duplicate OIDC identity accepted")
	}
	// Duplicate email.
	if _, err := s.Write().CreateUser(ctx, "venu3", "venu@example.com", "", "member", "", ""); err == nil {
		t.Fatal("duplicate email accepted")
	}
}

func TestGrantsRoundtrip(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	u, err := s.Write().CreateUser(ctx, "maya", "maya@example.com", "", "member", "", "")
	if err != nil {
		t.Fatal(err)
	}

	if err := s.Write().SetGrant(ctx, u.ID, "torrent", []string{"read", "write"}); err != nil {
		t.Fatal(err)
	}
	g, err := s.Read().GrantsForUser(ctx, u.ID)
	if err != nil || len(g) != 1 || len(g["torrent"]) != 2 {
		t.Fatalf("grants = %v, %v", g, err)
	}

	// Upsert narrows the actions (revoking write must actually revoke).
	if err := s.Write().SetGrant(ctx, u.ID, "torrent", []string{"read"}); err != nil {
		t.Fatal(err)
	}
	g, _ = s.Read().GrantsForUser(ctx, u.ID)
	if len(g["torrent"]) != 1 || g["torrent"][0] != "read" {
		t.Fatalf("narrowed grant = %v", g["torrent"])
	}

	if err := s.Write().RemoveGrant(ctx, u.ID, "torrent"); err != nil {
		t.Fatal(err)
	}
	g, _ = s.Read().GrantsForUser(ctx, u.ID)
	if len(g) != 0 {
		t.Fatalf("grants after remove = %v", g)
	}
}
