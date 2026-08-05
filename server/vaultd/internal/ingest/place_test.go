package ingest

import (
	"os"
	"path/filepath"
	"testing"
)

// The property that matters: after placing, BOTH paths are readable. If the
// source vanished, qBittorrent would report missing files and stop seeding —
// the exact bug this replaces.
func TestLinkKeepsSourceReadable(t *testing.T) {
	root := t.TempDir()
	src := filepath.Join(root, "Feature.mkv")
	if err := os.WriteFile(src, []byte("payload"), 0o640); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(root, "library", "Feature.mkv")

	hard, err := Link(src, dst)
	if err != nil {
		t.Fatalf("Link: %v", err)
	}
	if !hard {
		t.Fatal("same filesystem should hardlink, not copy")
	}
	for _, p := range []string{src, dst} {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("%s unreadable after Link: %v", p, err)
		}
		if string(b) != "payload" {
			t.Fatalf("%s has wrong content", p)
		}
	}
	// One inode, so the library entry costs nothing.
	si, _ := os.Stat(src)
	di, _ := os.Stat(dst)
	if !os.SameFile(si, di) {
		t.Fatal("hardlink should share the same inode")
	}
}

// Refusing to clobber is deliberate: collision-safe naming belongs to the
// catalog services, and a silent overwrite would destroy a library file.
func TestLinkRefusesToOverwrite(t *testing.T) {
	root := t.TempDir()
	src := filepath.Join(root, "a.mkv")
	dst := filepath.Join(root, "b.mkv")
	if err := os.WriteFile(src, []byte("new"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, []byte("existing"), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := Link(src, dst); err == nil {
		t.Fatal("Link overwrote an existing file")
	}
	if b, _ := os.ReadFile(dst); string(b) != "existing" {
		t.Fatal("existing file was modified")
	}
}

// A copy fallback must never leave a half-written file looking complete.
func TestCopyFallbackIsAtomic(t *testing.T) {
	root := t.TempDir()
	src := filepath.Join(root, "src.bin")
	if err := os.WriteFile(src, []byte("0123456789"), 0o640); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(root, "out", "dst.bin")
	if err := os.MkdirAll(filepath.Dir(dst), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := copyFile(src, dst+".partial"); err != nil {
		t.Fatalf("setup: %v", err)
	}
	// The real Link renames .partial into place; nothing should be visible at
	// the final name until that happens.
	if _, err := os.Stat(dst); !os.IsNotExist(err) {
		t.Fatal("destination visible before the copy was renamed into place")
	}
}
