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
