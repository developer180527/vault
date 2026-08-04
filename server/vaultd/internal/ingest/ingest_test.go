package ingest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func videoOK(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".mkv", ".mp4", ".avi":
		return true
	}
	return false
}

func audioOK(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".flac", ".mp3", ".m4a":
		return true
	}
	return false
}

// tree writes files of the given sizes, creating parents as needed.
func tree(t *testing.T, files map[string]int64) string {
	t.Helper()
	root := t.TempDir()
	for rel, size := range files {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
			t.Fatal(err)
		}
		f, err := os.Create(p)
		if err != nil {
			t.Fatal(err)
		}
		if size > 0 {
			if err := f.Truncate(size); err != nil {
				t.Fatal(err)
			}
		}
		f.Close()
	}
	return root
}

func names(paths []string) []string {
	out := make([]string, len(paths))
	for i, p := range paths {
		out[i] = filepath.Base(p)
	}
	return out
}

// The everyday case: one feature buried in the usual release litter.
func TestSelectPicksFeatureFromTypicalRelease(t *testing.T) {
	root := tree(t, map[string]int64{
		"Movie.2023.2160p.BluRay.x265.mkv": 20 << 30, // the feature
		"Sample/movie-sample.mkv":          40 << 20,
		"Movie.2023.nfo":                   2 << 10,
		"poster.jpg":                       500 << 10,
		"screens/shot1.png":                300 << 10,
		"RARBG.txt":                        100,
	})
	got, err := Select(root, videoOK)
	if err != nil {
		t.Fatalf("Select: %v", err)
	}
	if len(got.Files) != 1 {
		t.Fatalf("imported %v, want just the feature", names(got.Files))
	}
	if filepath.Base(got.Files[0]) != "Movie.2023.2160p.BluRay.x265.mkv" {
		t.Fatalf("picked %s, want the feature", filepath.Base(got.Files[0]))
	}
}

// A sample sitting NEXT TO the feature, not in a Sample/ folder — caught by
// the filename rule, and by size even if the name were unhelpful.
func TestSelectSkipsSiblingSample(t *testing.T) {
	root := tree(t, map[string]int64{
		"Film.mkv":        8 << 30,
		"Film-sample.mkv": 30 << 20,
		"sample.mkv":      25 << 20,
	})
	got, err := Select(root, videoOK)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Files) != 1 || filepath.Base(got.Files[0]) != "Film.mkv" {
		t.Fatalf("imported %v, want only Film.mkv", names(got.Files))
	}
	if len(got.Skipped) == 0 {
		t.Fatal("skipped files should be reported so the admin knows why")
	}
}

// An unlabelled extra is caught by SIZE alone — the rule that doesn't depend
// on the release group naming things helpfully.
func TestSelectSkipsTinyUnlabelledFile(t *testing.T) {
	root := tree(t, map[string]int64{
		"Feature.mkv":    10 << 30,
		"bonus_clip.mkv": 50 << 20, // 0.5% of the feature
	})
	got, err := Select(root, videoOK)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Files) != 1 || filepath.Base(got.Files[0]) != "Feature.mkv" {
		t.Fatalf("imported %v, want only Feature.mkv", names(got.Files))
	}
}

// A season pack is many comparable files and ALL of them are wanted — the
// size rule must not mistake episode 1 for "the content" and drop the rest.
func TestSelectKeepsAllEpisodesOfASeasonPack(t *testing.T) {
	root := tree(t, map[string]int64{
		"Show.S01E01.mkv":   2 << 30,
		"Show.S01E02.mkv":   2100 << 20,
		"Show.S01E03.mkv":   1900 << 20,
		"Sample/sample.mkv": 30 << 20,
	})
	got, err := Select(root, videoOK)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Files) != 3 {
		t.Fatalf("imported %v, want all three episodes", names(got.Files))
	}
}

// An album: every track matters, including the short ones, so long as they're
// not absurdly small next to the longest.
func TestSelectKeepsAllAlbumTracks(t *testing.T) {
	root := tree(t, map[string]int64{
		"Album/01 Opener.flac": 40 << 20,
		"Album/02 Single.flac": 35 << 20,
		"Album/03 Closer.flac": 55 << 20,
		"Album/cover.jpg":      2 << 20,
		"Album/folder.nfo":     1 << 10,
	})
	got, err := Select(root, audioOK)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Files) != 3 {
		t.Fatalf("imported %v, want all three tracks", names(got.Files))
	}
	// Largest first, so a caller that wants "the main one" gets it.
	if filepath.Base(got.Files[0]) != "03 Closer.flac" {
		t.Fatalf("first is %s, want the largest", filepath.Base(got.Files[0]))
	}
}

// A single-file torrent needs none of this machinery.
func TestSelectHandlesSingleFileDownload(t *testing.T) {
	root := tree(t, map[string]int64{"Solo.mkv": 5 << 30})
	got, err := Select(filepath.Join(root, "Solo.mkv"), videoOK)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Files) != 1 {
		t.Fatalf("got %v, want the file itself", names(got.Files))
	}
}

// A download with nothing playable must FAIL loudly. Silently importing
// nothing would leave the admin staring at an empty catalog entry.
func TestSelectFailsWhenNothingIsMedia(t *testing.T) {
	root := tree(t, map[string]int64{
		"readme.txt": 1 << 10,
		"cover.jpg":  2 << 20,
	})
	if _, err := Select(root, videoOK); err == nil {
		t.Fatal("a download with no media should be an error")
	}
	single := tree(t, map[string]int64{"notes.txt": 10})
	if _, err := Select(filepath.Join(single, "notes.txt"), videoOK); err == nil {
		t.Fatal("a single non-media file should be an error")
	}
}

// "Sample" as a real word in a title must not be discarded — the rule matches
// whole components, not substrings.
func TestSelectDoesNotEatLegitimateTitles(t *testing.T) {
	root := tree(t, map[string]int64{
		"The Sample Man (2019).mkv": 6 << 30,
		"Resampled.mkv":             5 << 30,
	})
	got, err := Select(root, videoOK)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Files) != 2 {
		t.Fatalf("imported %v, want both real titles kept", names(got.Files))
	}
}
