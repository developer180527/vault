// Package ingest works out what a finished download actually contains.
//
// A torrent is rarely one clean file. A typical movie release is a directory
// holding the feature plus a 40 MB sample, a poster, an .nfo, a "screens"
// folder and a RARBG.txt. Handing that whole directory to the library would
// either fail (it isn't a video file) or import junk as though it were
// content. So before anything is filed, we decide what the download was
// actually FOR.
//
// The rules, in order of how much work they do:
//
//  1. Extension — only files the destination can play are candidates at all.
//     That alone removes images, .nfo, .txt and stray subtitles.
//  2. Path names — a component like "sample", "extras" or "featurette" is a
//     strong, deliberate signal from whoever packaged the release.
//  3. SIZE, which does most of the real work. A sample is a rounding error
//     next to the feature (40 MB against 20 GB), and unlabelled junk is caught
//     by the same rule that catches labelled junk. Anything under a small
//     share of the largest candidate is not what you asked for.
//
// What survives is returned largest-first; the caller decides whether it wants
// one file (a movie) or all of them (an album, a season pack).
package ingest

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// minShareOfLargest: a candidate smaller than this fraction of the biggest one
// isn't the content. Deliberately generous — a two-part movie can have an
// uneven split, and a short album track can be a fraction of a long one, but
// nothing real is under a twentieth of the main file.
const minShareOfLargest = 0.05

// junkComponents mark a path as extras rather than the thing itself. Matched
// against whole, lowercased path components so a film legitimately called
// "The Sample" isn't discarded by a substring match.
var junkComponents = map[string]bool{
	"sample":      true,
	"samples":     true,
	"extras":      true,
	"extra":       true,
	"featurettes": true,
	"featurette":  true,
	"trailer":     true,
	"trailers":    true,
	"proof":       true,
	"screens":     true,
	"screenshots": true,
	"subs":        true,
	"subtitles":   true,
}

// Result describes what a download turned out to hold.
type Result struct {
	// Files worth importing, largest first. Empty means nothing usable.
	Files []string
	// Skipped is what was deliberately ignored, for the job's message — an
	// admin should be able to see WHY only one of nine files was imported
	// rather than wonder whether something went missing.
	Skipped []string
}

// Select walks a completed download at [root] and returns the files worth
// importing. [accept] gates by extension (music.AudioOK / movies.VideoOK), so
// this package stays independent of the catalog services.
//
// A [root] that is itself a single acceptable file is returned as-is — the
// common single-file torrent needs none of this.
func Select(root string, accept func(name string) bool) (Result, error) {
	return SelectOnly(root, accept, nil)
}

// SelectOnly is Select restricted to an explicit keep-set of torrent-relative
// paths — the user's own choice of which files they wanted.
//
// This is the ENFORCEMENT half of file selection. qBittorrent's per-file
// priorities are only a hint: it fetches pieces spanning a wanted/unwanted
// boundary and has a habit of writing skipped files anyway. So rather than
// trusting that the priority took, we check what is actually on disk against
// what the user asked for, and import only the intersection. A nil keep-set
// means "no selection recorded" and behaves exactly like [Select].
func SelectOnly(root string, accept func(name string) bool, keep []string) (Result, error) {
	if len(keep) == 0 {
		return selectAll(root, accept)
	}
	wanted := make(map[string]bool, len(keep))
	for _, p := range keep {
		wanted[filepath.ToSlash(strings.TrimPrefix(p, "/"))] = true
	}
	// qBittorrent reports paths relative to the torrent NAME, which is the
	// staging directory's own name for a multi-file torrent — so compare on
	// the tail, not on an absolute path neither side agrees about.
	base := filepath.Base(root)
	full, err := selectAll(root, accept)
	if err != nil {
		return full, err
	}
	var files []string
	skipped := full.Skipped
	for _, f := range full.Files {
		r := filepath.ToSlash(rel(root, f))
		if wanted[r] || wanted[base+"/"+r] {
			files = append(files, f)
			continue
		}
		skipped = append(skipped, r)
	}
	if len(files) == 0 {
		return Result{Skipped: skipped}, fmt.Errorf(
			"none of the selected files were downloaded")
	}
	return Result{Files: files, Skipped: skipped}, nil
}

func selectAll(root string, accept func(name string) bool) (Result, error) {
	info, err := os.Stat(root)
	if err != nil {
		return Result{}, err
	}
	if !info.IsDir() {
		if !accept(info.Name()) {
			return Result{}, fmt.Errorf(
				"downloaded file %q is not a supported media type", info.Name())
		}
		return Result{Files: []string{root}}, nil
	}

	type candidate struct {
		path string
		size int64
	}
	var kept []candidate
	var skipped []string

	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable entry: skip it, don't abort the import
		}
		if d.IsDir() {
			// Prune junk directories wholesale rather than filtering their
			// contents one by one.
			if path != root && junkComponents[strings.ToLower(d.Name())] {
				skipped = append(skipped, rel(root, path)+"/")
				return fs.SkipDir
			}
			return nil
		}
		name := d.Name()
		if !accept(name) {
			return nil // images, .nfo, .txt — not content, not worth reporting
		}
		if isJunkPath(root, path) {
			skipped = append(skipped, rel(root, path))
			return nil
		}
		fi, err := d.Info()
		if err != nil {
			return nil
		}
		kept = append(kept, candidate{path: path, size: fi.Size()})
		return nil
	})
	if err != nil {
		return Result{}, err
	}
	if len(kept) == 0 {
		return Result{Skipped: skipped}, fmt.Errorf(
			"no supported media found in the download")
	}

	sort.Slice(kept, func(i, j int) bool { return kept[i].size > kept[j].size })

	// Size filter, applied AFTER sorting so the threshold is set by the real
	// content rather than by whatever the walk happened to see first.
	largest := kept[0].size
	var files []string
	for _, c := range kept {
		if largest > 0 && float64(c.size) < float64(largest)*minShareOfLargest {
			skipped = append(skipped, rel(root, c.path))
			continue
		}
		files = append(files, c.path)
	}
	return Result{Files: files, Skipped: skipped}, nil
}

// isJunkPath reports whether any component between root and the file marks it
// as extras — including the filename's own stem, which catches the very common
// "Movie-sample.mkv" sitting beside the feature.
func isJunkPath(root, path string) bool {
	r := rel(root, path)
	parts := strings.Split(filepath.ToSlash(r), "/")
	for i, p := range parts {
		p = strings.ToLower(p)
		if i == len(parts)-1 {
			p = strings.TrimSuffix(p, filepath.Ext(p))
			// "sample", "movie-sample", "movie.sample" — but not "resample".
			for _, sep := range []string{"-", ".", "_", " "} {
				for _, j := range []string{"sample", "trailer"} {
					if p == j || strings.HasSuffix(p, sep+j) ||
						strings.HasPrefix(p, j+sep) {
						return true
					}
				}
			}
			continue
		}
		if junkComponents[p] {
			return true
		}
	}
	return false
}

func rel(root, path string) string {
	if r, err := filepath.Rel(root, path); err == nil {
		return r
	}
	return filepath.Base(path)
}
