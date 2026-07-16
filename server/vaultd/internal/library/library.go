// Package library manages per-user library directories under
// /srv/vault/users/<username>. See DESIGN.md "Data placement: convention
// over configuration" — services write only into these fixed zones.
package library

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// Zones are the fixed landing subdirectories every library gets.
var Zones = []string{"photos", "downloads", "files", "music"}

// usernameRx guards the one place a username becomes a filesystem path.
var usernameRx = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,31}$`)

// ValidUsername reports whether a username is safe as a library dir name.
func ValidUsername(u string) bool { return usernameRx.MatchString(u) }

// Sanitize lowercases and strips anything outside the username alphabet,
// falling back to `fallback` when nothing survives. Used where usernames are
// derived from IdP claims rather than typed by an admin.
func Sanitize(raw, fallback string) string {
	out := make([]byte, 0, len(raw))
	for _, c := range []byte(raw) {
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '.', c == '_', c == '-':
			out = append(out, c)
		case c >= 'A' && c <= 'Z':
			out = append(out, c+('a'-'A'))
		}
	}
	s := string(out)
	if !ValidUsername(s) {
		return fallback
	}
	return s
}

// Ensure creates (idempotently) the user's library and its zones, private to
// the vault user (0700). Called at enrollment; safe to call repeatedly.
func Ensure(dataRoot, username string) error {
	if !usernameRx.MatchString(username) {
		return fmt.Errorf("invalid username for library path: %q", username)
	}
	root := filepath.Join(dataRoot, "users", username)
	for _, dir := range append([]string{""}, Zones...) {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o700); err != nil {
			return fmt.Errorf("ensure library %s/%s: %w", username, dir, err)
		}
	}
	return nil
}
