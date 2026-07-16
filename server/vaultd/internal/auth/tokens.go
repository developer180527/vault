// Package auth: OIDC verification (who are you, answered by Pocket ID) and
// vaultd's own opaque device tokens (session state, answered by us).
//
// Tokens are 256-bit random values, stored only as sha256 hex. Opaque rather
// than JWT on purpose: revocation is a row delete, there is no signing key to
// rotate, and the DB lookup they require is a single indexed read.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"time"
)

const (
	// AccessTTL is how long an access token lives; clients refresh silently.
	AccessTTL = 15 * time.Minute

	// RotationGrace is how long the PREVIOUS refresh token keeps working
	// after a rotation. A double-refresh on a flaky connection must not
	// strand the device (DESIGN.md). Reuse OLDER than this is a theft
	// signal and revokes the device.
	RotationGrace = 60 * time.Second
)

// NewToken returns a fresh opaque token and its storage hash.
func NewToken() (plaintext, hash string) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand failure is not a recoverable state
	}
	plaintext = base64.RawURLEncoding.EncodeToString(b)
	return plaintext, HashToken(plaintext)
}

// HashToken maps a presented token to its storage form.
func HashToken(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}
