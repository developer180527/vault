package files

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newSvc(t *testing.T) (*Service, string) {
	t.Helper()
	root := t.TempDir()
	// Lay out a user library with the zones + a secret sibling to escape to.
	for _, z := range []string{"users/venu/files", "users/venu/downloads",
		"users/venu/photos", "users/venu/music"} {
		if err := os.MkdirAll(filepath.Join(root, z), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "users", "venu", "files", "note.txt"),
		[]byte("hi"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "secret.txt"), []byte("nope"), 0o600); err != nil {
		t.Fatal(err)
	}
	return &Service{DataRoot: root}, root
}

func TestSafeJoinRejectsEscapes(t *testing.T) {
	s, root := newSvc(t)
	userRoot := filepath.Join(root, "users", "venu")

	// Must be rejected.
	bad := []string{
		"../secret.txt",
		"../../etc/passwd",
		"files/../../secret.txt",
		"/etc/passwd",
		"files/../../../secret.txt",
		"..",
		"files/../..",
		"\x00files",
		".trash/x",        // hidden internals not addressable
		"files/../.trash", // resolves to a hidden segment
	}
	for _, rel := range bad {
		if _, err := s.SafeJoin("venu", rel); err == nil {
			t.Errorf("SafeJoin allowed escape: %q", rel)
		}
	}

	// Must be allowed and stay under the user root.
	good := []string{"", "files", "files/note.txt", "downloads", "files/sub/deep"}
	for _, rel := range good {
		got, err := s.SafeJoin("venu", rel)
		if err != nil {
			t.Errorf("SafeJoin rejected valid path %q: %v", rel, err)
			continue
		}
		if !strings.HasPrefix(got, userRoot) {
			t.Errorf("SafeJoin(%q) = %q escaped root %q", rel, got, userRoot)
		}
	}
}

func TestSafeJoinSymlinkEscape(t *testing.T) {
	s, root := newSvc(t)
	// Plant a symlink inside the library pointing OUT to the secret sibling.
	link := filepath.Join(root, "users", "venu", "files", "escape")
	if err := os.Symlink(filepath.Join(root, "secret.txt"), link); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}
	if _, err := s.SafeJoin("venu", "files/escape"); err == nil {
		t.Fatal("SafeJoin followed a symlink out of the library")
	}
}

func TestListRootShowsZones(t *testing.T) {
	s, _ := newSvc(t)
	nodes, err := s.List("venu", "")
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, n := range nodes {
		names[n.Name] = true
		if n.Kind != "folder" {
			t.Errorf("root node %s is not a folder", n.Name)
		}
	}
	for _, want := range []string{"Downloads", "Photos", "Music", "Files"} {
		if !names[want] {
			t.Errorf("root missing zone %q (got %v)", want, names)
		}
	}
}

func TestMkdirRenameTrash(t *testing.T) {
	s, root := newSvc(t)

	if _, err := s.Mkdir("venu", "files", "Trip"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "users", "venu", "files", "Trip")); err != nil {
		t.Fatalf("mkdir not created: %v", err)
	}

	if _, err := s.Rename("venu", "files/Trip", "Vacation"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "users", "venu", "files", "Vacation")); err != nil {
		t.Fatalf("rename target missing: %v", err)
	}

	// Trashing moves into .trash, never destroys.
	if err := s.Trash("venu", "files/note.txt"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "users", "venu", "files", "note.txt")); !os.IsNotExist(err) {
		t.Fatal("trashed file still in place")
	}
	trash, _ := os.ReadDir(filepath.Join(root, "users", "venu", ".trash"))
	if len(trash) != 1 {
		t.Fatalf("expected 1 trashed entry, got %d", len(trash))
	}

	// Zones can't be renamed or trashed.
	if _, err := s.Rename("venu", "files", "x"); err == nil {
		t.Error("renaming a zone was allowed")
	}
	if err := s.Trash("venu", "downloads"); err == nil {
		t.Error("trashing a zone was allowed")
	}
}

func TestMoveCopy(t *testing.T) {
	s, root := newSvc(t)
	if _, err := s.Mkdir("venu", "files", "Trip"); err != nil {
		t.Fatal(err)
	}

	// Copy note.txt into files/Trip — original stays, duplicate appears.
	if _, err := s.Copy("venu", "files/note.txt", "files/Trip"); err != nil {
		t.Fatalf("copy: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "users", "venu", "files", "note.txt")); err != nil {
		t.Fatal("copy removed the original")
	}
	if _, err := os.Stat(filepath.Join(root, "users", "venu", "files", "Trip", "note.txt")); err != nil {
		t.Fatalf("copy target missing: %v", err)
	}

	// Move it too — original gone, target present.
	if _, err := s.Move("venu", "files/note.txt", "files/Trip"); err == nil {
		// Trip/note.txt already exists from the copy → must be a conflict.
		t.Fatal("move onto an existing name should fail")
	}
	if _, err := s.Mkdir("venu", "files", "Away"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Move("venu", "files/note.txt", "files/Away"); err != nil {
		t.Fatalf("move: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "users", "venu", "files", "note.txt")); !os.IsNotExist(err) {
		t.Fatal("move left the original behind")
	}
	if _, err := os.Stat(filepath.Join(root, "users", "venu", "files", "Away", "note.txt")); err != nil {
		t.Fatalf("move target missing: %v", err)
	}

	// A zone root can't be moved, and a folder can't move into itself.
	if _, err := s.Move("venu", "files", "downloads"); err == nil {
		t.Error("moving a zone root was allowed")
	}
	if _, err := s.Move("venu", "files/Trip", "files/Trip"); err == nil {
		t.Error("moving a folder into itself was allowed")
	}
}

func TestUploadAtomicIngest(t *testing.T) {
	s, root := newSvc(t)
	node, err := s.Upload("venu", "files", "clip.mp4", strings.NewReader("videobytes"))
	if err != nil {
		t.Fatal(err)
	}
	if node.MediaKind != "video" {
		t.Errorf("media kind = %q, want video", node.MediaKind)
	}
	// The temp file must not survive.
	entries, _ := os.ReadDir(filepath.Join(root, "users", "venu", "files"))
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".incoming") {
			t.Fatal("ingest temp file left behind")
		}
	}
}

func TestIDRoundTrip(t *testing.T) {
	for _, rel := range []string{"files/a b/c.txt", "downloads", ""} {
		if got, err := DecodeID(EncodeID(rel)); err != nil || got != rel {
			t.Errorf("id round-trip %q → %q (err %v)", rel, got, err)
		}
	}
}
