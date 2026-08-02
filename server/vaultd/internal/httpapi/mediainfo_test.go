package httpapi

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/developer180527/vault/vaultd/internal/files"
	"github.com/developer180527/vault/vaultd/internal/movies"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// countingProber records how many times a file was probed, so the test can
// prove the cache actually spares the (slow) second probe.
type countingProber struct {
	res  *movies.ProbeResult
	hits int
}

func (p *countingProber) Probe(string) (*movies.ProbeResult, error) {
	p.hits++
	return p.res, nil
}

// A dual-audio MKV in a user's Files zone must expose the same track
// descriptor a catalog movie does — that's what gives ANY service the
// language picker.
func TestFileMediaInfoDescribesTracksAndCaches(t *testing.T) {
	// Japanese original + English dub, exactly the case in question.
	prober := &countingProber{res: &movies.ProbeResult{
		DurationMs: 6360000, VCodec: "h264", Width: 1920, Height: 1080,
		Audio: []store.AudioStream{
			{Index: 0, Lang: "jpn", Title: "Original", Codec: "aac", Default: true},
			{Index: 1, Lang: "eng", Title: "English Dub", Codec: "ac3", Channels: 6},
		},
		Subs: []store.SubStream{{Index: 0, Lang: "eng", Codec: "subrip", Text: true}},
	}}
	e := newTestEnv(t, func(o *Options) { o.Prober = prober })
	member := mintFilesMember(t, e, "rin", "sub-rin")

	// A "movie" sitting in the user's Files zone (not the movie catalog).
	rel := "files/Kimi no Na wa.mkv"
	abs := filepath.Join(e.dataRoot, "users", "rin", filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(abs), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(abs, []byte("matroska"), 0o640); err != nil {
		t.Fatal(err)
	}

	id := files.EncodeID(rel)
	code, body := e.call(t, "GET", "/v1/files/"+id+"/mediainfo", member, nil)
	if code != 200 {
		t.Fatalf("mediainfo = %d %v", code, body)
	}
	streams := body["streams"].(map[string]any)
	audio := streams["audio"].([]any)
	if len(audio) != 2 {
		t.Fatalf("audio tracks = %v", audio)
	}
	if audio[0].(map[string]any)["lang"] != "jpn" ||
		audio[1].(map[string]any)["lang"] != "eng" {
		t.Fatalf("languages wrong: %v", audio)
	}
	// The per-TYPE ordinal is what ffmpeg's -map wants; it must survive.
	if audio[1].(map[string]any)["index"].(float64) != 1 {
		t.Fatalf("track ordinal lost: %v", audio[1])
	}
	if body["vcodec"] != "h264" || body["height"].(float64) != 1080 {
		t.Fatalf("video meta = %v", body)
	}

	// Second call is served from cache — probing a 12GB file twice per
	// playback is exactly what this avoids.
	if _, _ = e.call(t, "GET", "/v1/files/"+id+"/mediainfo", member, nil); prober.hits != 1 {
		t.Fatalf("probe ran %d times, want 1 (cache miss)", prober.hits)
	}

	// Rewriting the file changes size+mtime → new key → re-probe, with no
	// manual invalidation anywhere.
	if err := os.WriteFile(abs, []byte("different bytes entirely"), 0o640); err != nil {
		t.Fatal(err)
	}
	e.call(t, "GET", "/v1/files/"+id+"/mediainfo", member, nil)
	if prober.hits != 2 {
		t.Fatalf("changed file not re-probed (hits=%d)", prober.hits)
	}
}
