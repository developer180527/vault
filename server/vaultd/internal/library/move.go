package library

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

// MoveInto moves srcPath into the user's <zone> (e.g. "downloads"),
// preserving the source's base name, and returns the final path.
//
// Atomic ingest (DESIGN.md): stream to a hidden temp file ON THE DESTINATION
// filesystem, fsync, then a local rename — so a crash mid-copy leaves only an
// invisible temp, never a half-written file a reader could see. Tries a plain
// rename first (instant when src and dst share a filesystem); on EXDEV
// (different ZFS datasets, the norm once per-user datasets exist) falls back
// to copy+rename. Handles both files and directories.
func MoveInto(dataRoot, username, zone, srcPath string) (string, error) {
	if !ValidUsername(username) {
		return "", fmt.Errorf("invalid username %q", username)
	}
	dstDir := filepath.Join(dataRoot, "users", username, zone)
	if err := os.MkdirAll(dstDir, 0o700); err != nil {
		return "", err
	}
	final := uniquePath(filepath.Join(dstDir, filepath.Base(srcPath)))

	// Fast path: same filesystem.
	if err := os.Rename(srcPath, final); err == nil {
		return final, nil
	} else if !isCrossDevice(err) {
		return "", err
	}

	// Cross-device: copy into a temp on the destination fs, then local rename.
	tmp := final + ".incoming"
	if err := copyTree(srcPath, tmp); err != nil {
		_ = os.RemoveAll(tmp)
		return "", err
	}
	if err := os.Rename(tmp, final); err != nil {
		_ = os.RemoveAll(tmp)
		return "", err
	}
	_ = os.RemoveAll(srcPath) // best-effort source cleanup
	return final, nil
}

func isCrossDevice(err error) bool {
	return errors.Is(err, syscall.EXDEV)
}

// uniquePath appends " (n)" before the extension until the path is free.
func uniquePath(p string) string {
	if _, err := os.Stat(p); os.IsNotExist(err) {
		return p
	}
	ext := filepath.Ext(p)
	base := p[:len(p)-len(ext)]
	for i := 2; ; i++ {
		cand := fmt.Sprintf("%s (%d)%s", base, i, ext)
		if _, err := os.Stat(cand); os.IsNotExist(err) {
			return cand
		}
	}
}

func copyTree(src, dst string) error {
	info, err := os.Lstat(src)
	if err != nil {
		return err
	}
	if info.IsDir() {
		if err := os.MkdirAll(dst, 0o700); err != nil {
			return err
		}
		entries, err := os.ReadDir(src)
		if err != nil {
			return err
		}
		for _, e := range entries {
			if err := copyTree(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())); err != nil {
				return err
			}
		}
		return nil
	}
	return copyFile(src, dst)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil { // durable before the rename
		out.Close()
		return err
	}
	return out.Close()
}
