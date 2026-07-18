package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// StreamSigner mints and verifies HMAC-signed stream URLs — the fix for the
// "bearer expires mid-listen" limitation (docs/MUSIC.md): a queue built by an
// authorized client carries per-track signed URLs valid for [StreamURLTTL],
// so loop restarts, queue wraps, and late seeks keep streaming long after the
// 15-minute access token died. The signature covers (payload, expiry); the
// URL itself is the capability — leaking one leaks ONE track for a bounded
// time, nothing else.
type StreamSigner struct {
	key []byte
}

// StreamURLTTL bounds a signed stream URL's life. Long enough for any
// listening session; short enough that a leaked URL goes stale in a day.
const StreamURLTTL = 24 * time.Hour

// LoadOrCreateStreamKey reads the signing key, generating and persisting it
// (0600) on first boot. Living under system/ it's covered by the same backup
// discipline as the DB; rotating it just invalidates in-flight URLs.
func LoadOrCreateStreamKey(path string) (*StreamSigner, error) {
	if b, err := os.ReadFile(path); err == nil && len(b) >= 32 {
		return &StreamSigner{key: b}, nil
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, key, 0o600); err != nil {
		return nil, fmt.Errorf("persist stream key: %w", err)
	}
	return &StreamSigner{key: key}, nil
}

// NewStreamSignerForTest builds a signer from a fixed key (tests only).
func NewStreamSignerForTest(key []byte) *StreamSigner {
	return &StreamSigner{key: key}
}

func (s *StreamSigner) mac(payload string, exp int64) string {
	m := hmac.New(sha256.New, s.key)
	fmt.Fprintf(m, "%s|%d", payload, exp)
	return hex.EncodeToString(m.Sum(nil))
}

// Sign returns (exp, sig) query values for [payload].
func (s *StreamSigner) Sign(payload string, now time.Time) (exp string, sig string) {
	e := now.Add(StreamURLTTL).Unix()
	return strconv.FormatInt(e, 10), s.mac(payload, e)
}

// Verify checks signature AND freshness. Fails closed on any parse error.
func (s *StreamSigner) Verify(payload, expStr, sig string, now time.Time) bool {
	e, err := strconv.ParseInt(expStr, 10, 64)
	if err != nil || now.Unix() >= e {
		return false
	}
	return hmac.Equal([]byte(s.mac(payload, e)), []byte(sig))
}
