package auth

import (
	"encoding/base64"
	"encoding/hex"
	"testing"
)

func TestNewTokenShapeAndHash(t *testing.T) {
	plain, hash := NewToken()

	// 256 bits of entropy, base64url without padding.
	raw, err := base64.RawURLEncoding.DecodeString(plain)
	if err != nil {
		t.Fatalf("plaintext not base64url: %v", err)
	}
	if len(raw) != 32 {
		t.Fatalf("token entropy = %d bytes, want 32", len(raw))
	}

	// The returned hash IS the storage form of the plaintext.
	if hash != HashToken(plain) {
		t.Fatal("returned hash doesn't match HashToken(plaintext)")
	}

	// sha256 hex: 64 lowercase hex chars, decodable.
	if len(hash) != 64 {
		t.Fatalf("hash length = %d, want 64", len(hash))
	}
	if _, err := hex.DecodeString(hash); err != nil {
		t.Fatalf("hash not hex: %v", err)
	}
}

func TestNewTokenUnique(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		plain, _ := NewToken()
		if seen[plain] {
			t.Fatal("duplicate token generated")
		}
		seen[plain] = true
	}
}

func TestHashTokenDeterministicAndDistinct(t *testing.T) {
	if HashToken("abc") != HashToken("abc") {
		t.Fatal("hash not deterministic")
	}
	if HashToken("abc") == HashToken("abd") {
		t.Fatal("distinct inputs collided")
	}
	// The plaintext must never appear in the storage form.
	if HashToken("secret-token") == "secret-token" {
		t.Fatal("hash is identity")
	}
}
