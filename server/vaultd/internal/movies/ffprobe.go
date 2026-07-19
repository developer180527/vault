package movies

import (
	"context"
	"encoding/json"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// ProbeResult is the parsed subset of ffprobe JSON we care about.
type ProbeResult struct {
	DurationMs int64
	Width      int
	Height     int
	VCodec     string
	Audio      []store.AudioStream
	Subs       []store.SubStream
}

// Prober extracts stream metadata from a video file. The real implementation
// shells out to ffprobe; tests inject a fake so no ffmpeg is needed.
type Prober interface {
	Probe(path string) (*ProbeResult, error)
}

// FFprobe is the production Prober.
type FFprobe struct{ Bin string }

// ffprobe's -show_streams/-show_format JSON shape (subset).
type ffStream struct {
	Index       int               `json:"index"`
	CodecName   string            `json:"codec_name"`
	CodecType   string            `json:"codec_type"`
	Channels    int               `json:"channels"`
	Width       int               `json:"width"`
	Height      int               `json:"height"`
	Disposition map[string]int    `json:"disposition"`
	Tags        map[string]string `json:"tags"`
}
type ffOutput struct {
	Streams []ffStream `json:"streams"`
	Format  struct {
		Duration string `json:"duration"`
	} `json:"format"`
}

func (f FFprobe) Probe(path string) (*ProbeResult, error) {
	bin := f.Bin
	if bin == "" {
		bin = "ffprobe"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin,
		"-v", "quiet", "-print_format", "json",
		"-show_format", "-show_streams", path).Output()
	if err != nil {
		return nil, err
	}
	var raw ffOutput
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil, err
	}
	return parseProbe(&raw), nil
}

// parseProbe converts ffprobe JSON into a ProbeResult. Audio/subtitle indices
// are per-TYPE ordinals (ffmpeg's `a:0`, `s:1`) so remux/extract map cleanly.
func parseProbe(raw *ffOutput) *ProbeResult {
	pr := &ProbeResult{}
	if secs, err := strconv.ParseFloat(raw.Format.Duration, 64); err == nil {
		pr.DurationMs = int64(secs * 1000)
	}
	var ai, si int
	for _, st := range raw.Streams {
		switch st.CodecType {
		case "video":
			if pr.VCodec == "" { // first video stream is the feature
				pr.VCodec = st.CodecName
				pr.Width = st.Width
				pr.Height = st.Height
			}
		case "audio":
			pr.Audio = append(pr.Audio, store.AudioStream{
				Index:    ai,
				Lang:     st.Tags["language"],
				Title:    st.Tags["title"],
				Codec:    st.CodecName,
				Channels: st.Channels,
				Default:  st.Disposition["default"] == 1,
			})
			ai++
		case "subtitle":
			pr.Subs = append(pr.Subs, store.SubStream{
				Index:  si,
				Lang:   st.Tags["language"],
				Title:  st.Tags["title"],
				Codec:  st.CodecName,
				Forced: st.Disposition["forced"] == 1,
				Text:   textSubCodecs[st.CodecName],
			})
			si++
		}
	}
	return pr
}

func applyProbe(pr *ProbeResult, m *store.CatalogMovie) {
	m.DurationMs = pr.DurationMs
	m.Width = pr.Width
	m.Height = pr.Height
	m.VCodec = pr.VCodec
	m.Streams.Audio = pr.Audio
	m.Streams.Subs = append(m.Streams.Subs, pr.Subs...)
}

// --- filename parsing ---

var (
	reSxxExx  = regexp.MustCompile(`(?i)s(\d{1,2})[._ -]?e(\d{1,3})`)
	reNxN     = regexp.MustCompile(`(?i)\b(\d{1,2})x(\d{1,3})\b`)
	reYear    = regexp.MustCompile(`(19|20)\d{2}`)
	reNoise   = regexp.MustCompile(`(?i)\b(1080p|720p|2160p|4k|x264|x265|hevc|web-?dl|bluray|bdrip|hdrip|dvdrip|aac|dts|ddp?5\.1|hdr)\b`)
	reSepRuns = regexp.MustCompile(`[._]+`)
	reSpaces  = regexp.MustCompile(`\s{2,}`)
)

func parseEpisode(base string) (season, episode int, ok bool) {
	if mm := reSxxExx.FindStringSubmatch(base); mm != nil {
		return atoiSafe(mm[1]), atoiSafe(mm[2]), true
	}
	if mm := reNxN.FindStringSubmatch(base); mm != nil {
		return atoiSafe(mm[1]), atoiSafe(mm[2]), true
	}
	return 0, 0, false
}

func stripEpisodeToken(base string) string {
	base = reSxxExx.ReplaceAllString(base, " ")
	base = reNxN.ReplaceAllString(base, " ")
	return base
}

func extractYear(base string) int {
	if y := reYear.FindString(base); y != "" {
		return atoiSafe(y)
	}
	return 0
}

func stripYear(base string) string {
	// Drop a trailing "(2019)" or bare year and everything after it.
	if loc := reYear.FindStringIndex(base); loc != nil {
		return base[:loc[0]]
	}
	return base
}

// cleanupName turns "The.Movie.2019.1080p.x264" fragments into "The Movie".
func cleanupName(s string) string {
	s = reSepRuns.ReplaceAllString(s, " ")
	s = reNoise.ReplaceAllString(s, " ")
	// Trim a dangling "(" left by year removal, brackets, stray separators.
	s = strings.Trim(s, " -([{")
	s = reSpaces.ReplaceAllString(s, " ")
	return strings.TrimSpace(s)
}
