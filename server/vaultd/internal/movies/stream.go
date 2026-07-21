package movies

import (
	"context"
	"fmt"
	"io"
	"os/exec"
)

// ffmpegBin returns the configured ffmpeg, defaulting to PATH.
func (s *Service) ffmpegBin() string {
	if s.FFmpegPath != "" {
		return s.FFmpegPath
	}
	return "ffmpeg"
}

// RemuxAudio streams the video with a NON-default audio track selected, as
// fragmented MP4 (streamable, AVPlayer/ExoPlayer-compatible). `-c copy` means
// NO re-encode — it's a container rewrite, ~zero CPU. This is how "play the
// English dub" works without a real transcode.
//
// [startSec] fast-seeks before decode so the client can resume/seek by
// re-requesting (a remuxed pipe can't serve HTTP Range).
func (s *Service) RemuxAudio(ctx context.Context, path string, audioIndex, startSec int, w io.Writer) error {
	args := []string{"-v", "error"}
	if startSec > 0 {
		args = append(args, "-ss", fmt.Sprint(startSec))
	}
	args = append(args,
		"-i", path,
		"-map", "0:v:0",
		"-map", fmt.Sprintf("0:a:%d", audioIndex),
		"-c", "copy",
		// Fragmented MP4 so it streams without a seekable output.
		"-movflags", "+frag_keyframe+empty_moov+default_base_moof",
		"-f", "mp4", "pipe:1",
	)
	cmd := exec.CommandContext(ctx, s.ffmpegBin(), args...)
	cmd.Stdout = w
	return cmd.Run()
}

// Transcode RE-ENCODES to H.264/AAC in fragmented MP4 — the path for codecs
// the client can't decode natively (HEVC-in-MKV, VP9, AV1, AC3/DTS audio…).
// Unlike [RemuxAudio] this is a real, CPU-heavy encode; callers MUST gate it
// behind [TryAcquireTranscode] so a few viewers can't peg every core.
//
// Progressive fMP4 (same streaming model as remux): no HTTP Range, so seeking
// is a re-request with [startSec] (ffmpeg fast-seeks before decode). `-preset
// veryfast` trades size for CPU — right for on-the-fly on a home box; hardware
// encoders (videotoolbox/vaapi/nvenc) are a future tuning knob per host.
func (s *Service) Transcode(ctx context.Context, path string, audioIndex, startSec int, w io.Writer) error {
	args := []string{"-v", "error"}
	if startSec > 0 {
		args = append(args, "-ss", fmt.Sprint(startSec))
	}
	args = append(args,
		"-i", path,
		"-map", "0:v:0",
		"-map", fmt.Sprintf("0:a:%d", audioIndex),
		"-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
		"-pix_fmt", "yuv420p", // 8-bit 4:2:0 — universally decodable
		"-c:a", "aac", "-ac", "2", "-b:a", "160k",
		"-movflags", "+frag_keyframe+empty_moov+default_base_moof",
		"-f", "mp4", "pipe:1",
	)
	cmd := exec.CommandContext(ctx, s.ffmpegBin(), args...)
	cmd.Stdout = w
	return cmd.Run()
}

// TryAcquireTranscode reserves a transcode slot, or returns false if all are
// busy (the caller answers 503). Lazily sized from MaxConcurrentTranscodes
// (default 2). Cheap re-encodes (remux, subtitles) are NOT gated — only real
// video encodes contend for CPU.
func (s *Service) TryAcquireTranscode() bool {
	s.semOnce.Do(func() {
		n := s.MaxConcurrentTranscodes
		if n <= 0 {
			n = 2
		}
		s.sem = make(chan struct{}, n)
	})
	select {
	case s.sem <- struct{}{}:
		return true
	default:
		return false
	}
}

// ReleaseTranscode frees a slot acquired by [TryAcquireTranscode].
func (s *Service) ReleaseTranscode() { <-s.sem }

// ExtractSubVTT converts one EMBEDDED text subtitle track to WebVTT, streamed.
// The client feeds this to video_player's closed-caption overlay.
func (s *Service) ExtractSubVTT(ctx context.Context, path string, subIndex int, w io.Writer) error {
	cmd := exec.CommandContext(ctx, s.ffmpegBin(),
		"-v", "error",
		"-i", path,
		"-map", fmt.Sprintf("0:s:%d", subIndex),
		"-f", "webvtt", "pipe:1",
	)
	cmd.Stdout = w
	return cmd.Run()
}

// ConvertSidecarVTT converts a sidecar subtitle FILE (.srt/.ass) to WebVTT.
func (s *Service) ConvertSidecarVTT(ctx context.Context, subPath string, w io.Writer) error {
	cmd := exec.CommandContext(ctx, s.ffmpegBin(),
		"-v", "error", "-i", subPath, "-f", "webvtt", "pipe:1")
	cmd.Stdout = w
	return cmd.Run()
}
