package music

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// mp4FaststartExt are the MP4/QuickTime-family containers whose metadata
// (`moov`) placement matters for streaming. ADTS .aac, .mp3, .flac, etc. have
// no atom layout, so they're never candidates.
var mp4FaststartExt = map[string]bool{
	".m4a": true, ".mp4": true, ".m4v": true, ".mov": true, ".m4b": true,
}

// ffmpegBin returns the configured ffmpeg, defaulting to PATH.
func (s *Service) ffmpegBin() string {
	if s.FFmpegPath != "" {
		return s.FFmpegPath
	}
	return "ffmpeg"
}

// needsFaststart reports whether an MP4-family file has its `moov` atom AFTER
// the media data (`mdat`) — the layout that forces a player to fetch the whole
// payload before it can start. It walks only the top-level box headers (8–16
// bytes each), never the media, so it's a few small reads regardless of file
// size. A file with `moov` first (already faststart) returns false.
func needsFaststart(path string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()

	var off int64
	hdr := make([]byte, 16)
	for {
		if _, err := f.ReadAt(hdr[:8], off); err != nil {
			if err == io.EOF {
				return false, nil // no moov/mdat seen — leave it alone
			}
			return false, err
		}
		size := int64(binary.BigEndian.Uint32(hdr[:4]))
		typ := string(hdr[4:8])
		headerLen := int64(8)
		switch size {
		case 1: // 64-bit extended size follows the type
			if _, err := f.ReadAt(hdr[8:16], off+8); err != nil {
				return false, err
			}
			size = int64(binary.BigEndian.Uint64(hdr[8:16]))
			headerLen = 16
		case 0: // box extends to EOF — it's the last one
			switch typ {
			case "moov":
				return false, nil
			case "mdat":
				return true, nil
			}
			return false, nil
		}
		switch typ {
		case "moov":
			return false, nil // metadata first → already streamable
		case "mdat":
			return true, nil // media before metadata → needs faststart
		}
		if size < headerLen {
			return false, nil // malformed; don't touch it
		}
		off += size
	}
}

// OptimizeFaststart rewrites catalog tracks whose `moov` atom sits after the
// media so the metadata leads the file — a lossless `-c copy` remux (no
// re-encode), written atomically (.part + rename) so a crash never corrupts a
// track. Returns how many were optimized and how many were already fine.
// Idempotent: a second run is all skips.
func (s *Service) OptimizeFaststart(ctx context.Context) (optimized, skipped int, err error) {
	root := s.CatalogRoot()
	entries, err := os.ReadDir(root)
	if err != nil {
		return 0, 0, err
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasPrefix(name, ".") {
			continue // dot-sidecars (.art, .part) are never media
		}
		if !mp4FaststartExt[strings.ToLower(filepath.Ext(name))] {
			continue
		}
		path := filepath.Join(root, name)
		need, perr := needsFaststart(path)
		if perr != nil {
			s.Log.Warn("faststart probe failed", "file", name, "err", perr)
			continue
		}
		if !need {
			skipped++
			continue
		}
		if rerr := s.remuxFaststart(ctx, path); rerr != nil {
			s.Log.Warn("faststart remux failed", "file", name, "err", rerr)
			continue
		}
		optimized++
	}
	return optimized, skipped, nil
}

// remuxFaststart runs the lossless container rewrite into a temp file, then
// atomically replaces the original.
func (s *Service) remuxFaststart(ctx context.Context, path string) error {
	tmp := path + ".part"
	// -c copy: no re-encode. +faststart moves moov to the front (ffmpeg does a
	// two-pass write internally). Overwrite any stale .part with -y.
	cmd := exec.CommandContext(ctx, s.ffmpegBin(),
		"-v", "error", "-y", "-i", path,
		"-c", "copy", "-movflags", "+faststart", "-f", extFormat(path), tmp)
	if out, err := cmd.CombinedOutput(); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("ffmpeg: %v: %s", err, strings.TrimSpace(string(out)))
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// extFormat maps an extension to ffmpeg's muxer name (the .part temp has no
// recognizable extension, so -f is explicit). All the faststart-eligible
// containers mux as "mp4" in ffmpeg except QuickTime .mov.
func extFormat(path string) string {
	if strings.ToLower(filepath.Ext(path)) == ".mov" {
		return "mov"
	}
	return "mp4"
}
