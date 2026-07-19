package movies

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/developer180527/vault/vaultd/internal/store"
)

func TestParseFilename(t *testing.T) {
	cases := []struct {
		rel                    string
		wantKind, wantTitle    string
		wantSeries             string
		wantYear, wantS, wantE int
	}{
		{"The Matrix (1999).mkv", "movie", "The Matrix", "", 1999, 0, 0},
		{"Inception.2010.1080p.x264.mp4", "movie", "Inception", "", 2010, 0, 0},
		{"Breaking Bad/Season 1/S01E03 - And the Bag.mkv",
			"episode", "And the Bag", "Breaking Bad", 0, 1, 3},
		{"Firefly/1x05 Safe.mkv", "episode", "Safe", "Firefly", 0, 1, 5},
	}
	for _, c := range cases {
		var m store.CatalogMovie
		parseFilename(c.rel, &m)
		if m.Kind != c.wantKind || m.Title != c.wantTitle ||
			m.Series != c.wantSeries || m.Year != c.wantYear ||
			m.Season != c.wantS || m.Episode != c.wantE {
			t.Errorf("%q → %+v (want kind=%s title=%q series=%q year=%d s=%d e=%d)",
				c.rel, m, c.wantKind, c.wantTitle, c.wantSeries, c.wantYear,
				c.wantS, c.wantE)
		}
	}
}

func TestParseProbeStreams(t *testing.T) {
	// Two audio (Japanese default + English dub), one text sub, one image sub.
	raw := `{"format":{"duration":"1440.5"},"streams":[
		{"index":0,"codec_type":"video","codec_name":"h264","width":1920,"height":1080},
		{"index":1,"codec_type":"audio","codec_name":"aac","channels":2,
		 "disposition":{"default":1},"tags":{"language":"jpn","title":"Original"}},
		{"index":2,"codec_type":"audio","codec_name":"ac3","channels":6,
		 "tags":{"language":"eng","title":"English Dub"}},
		{"index":3,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng"}},
		{"index":4,"codec_type":"subtitle","codec_name":"hdmv_pgs_subtitle","tags":{"language":"eng"}}
	]}`
	var out ffOutput
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatal(err)
	}
	pr := parseProbe(&out)
	if pr.DurationMs != 1440500 || pr.VCodec != "h264" || pr.Width != 1920 {
		t.Fatalf("video meta = %+v", pr)
	}
	if len(pr.Audio) != 2 || pr.Audio[0].Lang != "jpn" || !pr.Audio[0].Default ||
		pr.Audio[1].Lang != "eng" || pr.Audio[1].Index != 1 {
		t.Fatalf("audio = %+v", pr.Audio)
	}
	if len(pr.Subs) != 2 || !pr.Subs[0].Text || pr.Subs[1].Text {
		t.Fatalf("subs (want srt text, pgs non-text) = %+v", pr.Subs)
	}
}

// fakeProber returns canned probe output — no ffmpeg on the box.
type fakeProber struct{ res *ProbeResult }

func (f fakeProber) Probe(string) (*ProbeResult, error) { return f.res, nil }

func TestScanIndexesAndDetectsSidecarSubs(t *testing.T) {
	root := t.TempDir()
	dbPath := filepath.Join(t.TempDir(), "v.db")
	st, err := store.Open(context.Background(), dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	// A movie file + an English sidecar subtitle beside it.
	dir := filepath.Join(root, "Movies")
	_ = os.MkdirAll(dir, 0o750)
	_ = os.WriteFile(filepath.Join(dir, "Arrival (2016).mkv"), []byte("v"), 0o640)
	_ = os.WriteFile(filepath.Join(dir, "Arrival (2016).en.srt"), []byte("1\n"), 0o640)
	// A non-video file that must be ignored.
	_ = os.WriteFile(filepath.Join(dir, "readme.txt"), []byte("x"), 0o640)

	svc := &Service{
		Root: root, Store: st, Log: slog.New(slog.DiscardHandler),
		Prober: fakeProber{res: &ProbeResult{
			DurationMs: 6000000, VCodec: "hevc", Width: 3840, Height: 2160,
			Audio: []store.AudioStream{{Index: 0, Lang: "eng", Codec: "eac3", Default: true}},
		}},
	}
	added, pruned, err := svc.Scan(context.Background())
	if err != nil || added != 1 || pruned != 0 {
		t.Fatalf("scan = %d/%d %v", added, pruned, err)
	}
	movies, _ := st.Read().Movies(context.Background())
	if len(movies) != 1 {
		t.Fatalf("movies = %d", len(movies))
	}
	m := movies[0]
	if m.Title != "Arrival" || m.Year != 2016 || m.VCodec != "hevc" {
		t.Fatalf("meta = %+v", m)
	}
	// One embedded audio from the probe, one sidecar sub discovered.
	if len(m.Streams.Audio) != 1 || len(m.Streams.Subs) != 1 ||
		m.Streams.Subs[0].External == "" || m.Streams.Subs[0].Lang != "en" {
		t.Fatalf("streams = %+v", m.Streams)
	}

	// Delete the file → next scan prunes the row.
	_ = os.Remove(filepath.Join(dir, "Arrival (2016).mkv"))
	_, pruned, _ = svc.Scan(context.Background())
	if pruned != 1 {
		t.Fatalf("prune = %d, want 1", pruned)
	}
}
