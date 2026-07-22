package library

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// Two concurrent moves of DIFFERENT files that share a basename must both land
// under distinct names — never clobber each other (the uniquePath TOCTOU).
func TestMoveIntoConcurrentSameName(t *testing.T) {
	root := t.TempDir()

	mk := func(dir, content string) string {
		d := filepath.Join(root, "src", dir)
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
		p := filepath.Join(d, "clip.mp4")
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	srcs := []string{mk("a", "one"), mk("b", "two")}

	var wg sync.WaitGroup
	results := make([]string, len(srcs))
	errs := make([]error, len(srcs))
	for i := range srcs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i], errs[i] = MoveInto(root, "venu", "downloads", srcs[i])
		}(i)
	}
	wg.Wait()

	for i, e := range errs {
		if e != nil {
			t.Fatalf("move %d failed: %v", i, e)
		}
	}
	if results[0] == results[1] {
		t.Fatalf("both moves landed on the same path: %s", results[0])
	}
	// Both payloads survived (distinct content, nothing overwritten).
	seen := map[string]bool{}
	for i, p := range results {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("result %d missing: %v", i, err)
		}
		seen[string(b)] = true
	}
	if !seen["one"] || !seen["two"] {
		t.Fatalf("a payload was clobbered; contents seen = %v", seen)
	}

	// Exactly two visible files, no leftover ".incoming" temps.
	entries, err := os.ReadDir(filepath.Join(root, "users", "venu", "downloads"))
	if err != nil {
		t.Fatal(err)
	}
	var visible int
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), ".") {
			visible++
		}
	}
	if visible != 2 {
		t.Fatalf("expected 2 files, got %d: %v", visible, entries)
	}
}
