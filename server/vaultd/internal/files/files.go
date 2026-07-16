// Package files is the My Files service: browsing and managing a user's
// library over the filesystem. The visible root is the WHOLE library — the
// four fixed zones (Downloads, Photos, Music, Files) appear as top-level
// folders, so generated data (torrents, backups) is always findable.
//
// Node IDs are opaque handles: base64url of the user-relative path. Per
// DESIGN.md these are NON-PERSISTABLE (a parent rename changes descendants'
// IDs); rename-stable IDs arrive with the nodes table when pin/sync ship.
package files

import (
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/developer180527/vault/vaultd/internal/library"
)

// Service exposes one user-library filesystem view.
type Service struct {
	DataRoot string
}

// ErrInvalidPath is returned for any path that fails SafeJoin.
var ErrInvalidPath = errors.New("invalid path")

// ErrNotFound mirrors store.ErrNotFound for fs entities.
var ErrNotFound = errors.New("not found")

// Node is one entry in the library.
type Node struct {
	ID         string    `json:"id"`
	ParentID   *string   `json:"parent_id"` // nil at the library root
	Name       string    `json:"name"`
	Kind       string    `json:"kind"` // "folder" | "file"
	Size       int64     `json:"size"`
	ModifiedAt time.Time `json:"modified_at"`
	MediaKind  string    `json:"media_kind"` // none|image|video|audio|document
	ChildCount int       `json:"child_count"`
}

// EncodeID turns a user-relative path into an opaque node id.
func EncodeID(rel string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(rel))
}

// DecodeID reverses EncodeID. Empty id = library root.
func DecodeID(id string) (string, error) {
	if id == "" {
		return "", nil
	}
	b, err := base64.RawURLEncoding.DecodeString(id)
	if err != nil {
		return "", ErrInvalidPath
	}
	return string(b), nil
}

// SafeJoin resolves a user-relative path against the user's library root and
// guarantees the result cannot escape it: cleans the path, rejects absolute
// paths and any ".." traversal, and resolves symlinks in the EXISTING part of
// the path, verifying it still hangs off the resolved root. THE one place a
// client path touches the filesystem (DESIGN.md).
func (s *Service) SafeJoin(username, rel string) (string, error) {
	if !library.ValidUsername(username) {
		return "", ErrInvalidPath
	}
	root := filepath.Join(s.DataRoot, "users", username)

	if strings.Contains(rel, "\x00") || filepath.IsAbs(rel) {
		return "", ErrInvalidPath
	}
	// Reject on the RAW segments (before any cleaning that could silently
	// collapse a "..") : no traversal, no hidden internals (.trash, ingest
	// temps). "." and empty segments are harmless and get cleaned away.
	for _, seg := range strings.Split(rel, "/") {
		if seg == ".." {
			return "", ErrInvalidPath
		}
		if strings.HasPrefix(seg, ".") && seg != "." && seg != "" {
			return "", ErrInvalidPath
		}
	}
	cleaned := strings.TrimPrefix(filepath.Clean("/"+rel), "/")
	joined := filepath.Join(root, cleaned)

	// Resolve symlinks on the deepest existing ancestor and confirm it's
	// still inside the (resolved) root.
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	existing := joined
	for {
		if r, err := filepath.EvalSymlinks(existing); err == nil {
			if r != resolvedRoot && !strings.HasPrefix(r, resolvedRoot+string(filepath.Separator)) {
				return "", ErrInvalidPath
			}
			break
		}
		parent := filepath.Dir(existing)
		if parent == existing {
			return "", ErrInvalidPath
		}
		existing = parent
	}
	return joined, nil
}

// zoneNames maps zone dirs to display names shown at the root.
var zoneNames = map[string]string{
	"downloads": "Downloads",
	"photos":    "Photos",
	"music":     "Music",
	"files":     "Files",
}

// List returns the children of a node (empty rel = library root → zones).
func (s *Service) List(username, rel string) ([]Node, error) {
	if rel == "" {
		return s.listRoot(username)
	}
	abs, err := s.SafeJoin(username, rel)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(abs)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	nodes := make([]Node, 0, len(entries))
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".") {
			continue // trash, ingest temps
		}
		n, err := s.nodeFor(username, filepath.Join(rel, e.Name()))
		if err != nil {
			continue
		}
		nodes = append(nodes, *n)
	}
	sortNodes(nodes)
	return nodes, nil
}

func (s *Service) listRoot(username string) ([]Node, error) {
	var nodes []Node
	for _, zone := range library.Zones {
		n, err := s.nodeFor(username, zone)
		if err != nil {
			continue // zone missing (old account) — Ensure fixes on next login
		}
		n.Name = zoneNames[zone]
		nodes = append(nodes, *n)
	}
	sortNodes(nodes)
	return nodes, nil
}

// Stat returns one node by relative path.
func (s *Service) Stat(username, rel string) (*Node, error) {
	if rel == "" {
		return nil, ErrNotFound // the root itself isn't a node
	}
	return s.nodeFor(username, rel)
}

// PathChain returns the breadcrumb nodes from the first component down to rel.
func (s *Service) PathChain(username, rel string) ([]Node, error) {
	if rel == "" {
		return nil, nil
	}
	segs := strings.Split(rel, "/")
	chain := make([]Node, 0, len(segs))
	for i := range segs {
		sub := strings.Join(segs[:i+1], "/")
		n, err := s.nodeFor(username, sub)
		if err != nil {
			return nil, err
		}
		if i == 0 {
			if disp, ok := zoneNames[segs[0]]; ok {
				n.Name = disp
			}
		}
		chain = append(chain, *n)
	}
	return chain, nil
}

// Mkdir creates a folder under parentRel and returns its node.
func (s *Service) Mkdir(username, parentRel, name string) (*Node, error) {
	if err := validName(name); err != nil {
		return nil, err
	}
	rel := filepath.Join(parentRel, name)
	abs, err := s.SafeJoin(username, rel)
	if err != nil {
		return nil, err
	}
	if err := os.Mkdir(abs, 0o700); err != nil {
		return nil, err
	}
	return s.nodeFor(username, rel)
}

// Rename changes a node's basename (its parent stays fixed).
func (s *Service) Rename(username, rel, newName string) (*Node, error) {
	if err := validName(newName); err != nil {
		return nil, err
	}
	if isZoneRoot(rel) {
		return nil, ErrInvalidPath // zones are fixed
	}
	abs, err := s.SafeJoin(username, rel)
	if err != nil {
		return nil, err
	}
	newRel := filepath.Join(filepath.Dir(rel), newName)
	newAbs, err := s.SafeJoin(username, newRel)
	if err != nil {
		return nil, err
	}
	if err := os.Rename(abs, newAbs); err != nil {
		return nil, err
	}
	return s.nodeFor(username, newRel)
}

// Trash soft-deletes: moves the node into the library's hidden .trash with a
// timestamp prefix (never destroys — DESIGN.md).
func (s *Service) Trash(username, rel string) error {
	if isZoneRoot(rel) {
		return ErrInvalidPath
	}
	abs, err := s.SafeJoin(username, rel)
	if err != nil {
		return err
	}
	trashDir := filepath.Join(s.DataRoot, "users", username, ".trash")
	if err := os.MkdirAll(trashDir, 0o700); err != nil {
		return err
	}
	dst := filepath.Join(trashDir,
		fmt.Sprintf("%d-%s", time.Now().Unix(), filepath.Base(rel)))
	return os.Rename(abs, dst)
}

// Upload streams body into parentRel/name via atomic ingest: hidden temp in
// the destination dir, fsync, rename. Returns the created node.
func (s *Service) Upload(username, parentRel, name string, body io.Reader) (*Node, error) {
	if err := validName(name); err != nil {
		return nil, err
	}
	rel := filepath.Join(parentRel, name)
	abs, err := s.SafeJoin(username, rel)
	if err != nil {
		return nil, err
	}
	tmp := filepath.Join(filepath.Dir(abs), ".incoming-"+filepath.Base(abs))
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, err
	}
	if _, err := io.Copy(out, body); err != nil {
		out.Close()
		_ = os.Remove(tmp)
		return nil, err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		_ = os.Remove(tmp)
		return nil, err
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(tmp)
		return nil, err
	}
	if err := os.Rename(tmp, abs); err != nil {
		_ = os.Remove(tmp)
		return nil, err
	}
	return s.nodeFor(username, rel)
}

// Open returns the file for streaming (caller closes) plus its info.
func (s *Service) Open(username, rel string) (*os.File, os.FileInfo, error) {
	abs, err := s.SafeJoin(username, rel)
	if err != nil {
		return nil, nil, err
	}
	f, err := os.Open(abs)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil, ErrNotFound
		}
		return nil, nil, err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, err
	}
	if info.IsDir() {
		f.Close()
		return nil, nil, ErrInvalidPath
	}
	return f, info, nil
}

// --- helpers ---

func (s *Service) nodeFor(username, rel string) (*Node, error) {
	abs, err := s.SafeJoin(username, rel)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	n := &Node{
		ID:         EncodeID(rel),
		Name:       filepath.Base(rel),
		ModifiedAt: info.ModTime(),
	}
	if parent := filepath.Dir(rel); parent != "." {
		pid := EncodeID(parent)
		n.ParentID = &pid
	}
	if info.IsDir() {
		n.Kind = "folder"
		if entries, err := os.ReadDir(abs); err == nil {
			count := 0
			for _, e := range entries {
				if !strings.HasPrefix(e.Name(), ".") {
					count++
				}
			}
			n.ChildCount = count
		}
	} else {
		n.Kind = "file"
		n.Size = info.Size()
		n.MediaKind = mediaKindFor(rel)
	}
	return n, nil
}

func sortNodes(nodes []Node) {
	sort.Slice(nodes, func(i, j int) bool {
		if (nodes[i].Kind == "folder") != (nodes[j].Kind == "folder") {
			return nodes[i].Kind == "folder"
		}
		return strings.ToLower(nodes[i].Name) < strings.ToLower(nodes[j].Name)
	})
}

func validName(name string) error {
	if name == "" || name == "." || name == ".." ||
		strings.ContainsAny(name, "/\x00") || strings.HasPrefix(name, ".") {
		return ErrInvalidPath
	}
	return nil
}

func isZoneRoot(rel string) bool {
	_, ok := zoneNames[rel]
	return ok
}

// mediaKindFor mirrors the client's extension mapping.
func mediaKindFor(name string) string {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))
	switch ext {
	case "jpg", "jpeg", "png", "gif", "heic", "webp":
		return "image"
	case "mp4", "mov", "mkv", "avi", "webm":
		return "video"
	case "mp3", "flac", "wav", "m4a", "ogg", "opus":
		return "audio"
	case "pdf", "doc", "docx", "txt", "md":
		return "document"
	}
	return "none"
}
