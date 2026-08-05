package ingest

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// Getting a finished download into the library WITHOUT killing the seed.
//
// Moving the file is the obvious thing and the wrong thing: qBittorrent is
// still seeding from it, so a move makes the torrent report "missing files"
// and the upload stops dead. That silently turned every completed download
// into a leech.
//
// So, in order of preference:
//
//  1. HARDLINK. Two names, one set of blocks — the library gets its own entry,
//     qBittorrent keeps seeding from the original, and it costs no extra disk
//     and no time even for a 40 GB feature. This is what the arr-stack does,
//     and it's the reason its "keep seeding" story works.
//  2. COPY, when a hardlink can't cross the boundary (staging on the root disk,
//     library on the ZFS pool — exactly this deployment). Costs the bytes and
//     the time, but seeding survives.
//
// Deleting the staged copy is never our call: the user removes the torrent
// when they're done seeding, and that's what reclaims the space.

// Link places [src] at [dst] cheaply if it can, copying if it must. Returns
// true when a hardlink was used (no extra space consumed).
//
// [dst] must not already exist — callers resolve collisions first, so a
// surprise overwrite can't happen here.
func Link(src, dst string) (hardlinked bool, err error) {
	if err := os.MkdirAll(filepath.Dir(dst), 0o750); err != nil {
		return false, err
	}
	if _, err := os.Stat(dst); err == nil {
		return false, fmt.Errorf("destination already exists: %s", dst)
	}
	// Same filesystem: instant, free, and the seed keeps its blocks.
	if err := os.Link(src, dst); err == nil {
		return true, nil
	}
	// Cross-device (or a filesystem without links): pay for a copy so seeding
	// still survives. A partial copy must never be left looking complete, so
	// write to a temp name and rename into place.
	tmp := dst + ".partial"
	if err := copyFile(src, tmp); err != nil {
		_ = os.Remove(tmp)
		return false, err
	}
	if err := os.Rename(tmp, dst); err != nil {
		_ = os.Remove(tmp)
		return false, err
	}
	return false, nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0o640)
	if err != nil {
		return err
	}
	// 4 MB buffer: the default 32 KB means ~1.3M syscalls for a 40 GB feature.
	buf := make([]byte, 4<<20)
	_, err = io.CopyBuffer(out, in, buf)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return err
}
