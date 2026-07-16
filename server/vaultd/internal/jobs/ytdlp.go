package jobs

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"syscall"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// YtdlpRunner downloads a URL with yt-dlp into a per-job staging dir, then
// hands the produced file to the engine to move into the user's library.
type YtdlpRunner struct {
	// Binary is the yt-dlp executable (default "yt-dlp").
	Binary string
	// StagingRoot is /srv/vault/staging/ytdlp.
	StagingRoot string
}

var _ Runner = (*YtdlpRunner)(nil)

// progressRx matches yt-dlp's --newline progress lines, e.g. "[download]  42.3% of ...".
var progressRx = regexp.MustCompile(`\[download\]\s+([0-9.]+)%`)

func (y *YtdlpRunner) Run(ctx context.Context, job store.Job, report func(float64, string)) (string, error) {
	bin := y.Binary
	if bin == "" {
		bin = "yt-dlp"
	}
	// One dir per job so concurrent downloads never collide; the engine moves
	// the result out on success and we clean the dir up.
	jobDir := filepath.Join(y.StagingRoot, job.ID)
	if err := os.MkdirAll(jobDir, 0o770); err != nil {
		return "", err
	}
	defer os.RemoveAll(jobDir)

	report(0, "starting")
	cmd := exec.CommandContext(ctx, bin,
		"--newline", "--no-playlist", "--restrict-filenames",
		"-o", filepath.Join(jobDir, "%(title)s.%(ext)s"),
		job.Source,
	)
	// Own process group so cancellation kills yt-dlp AND ffmpeg children
	// (no orphans on cancel/shutdown — DESIGN.md).
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process != nil {
			return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
		return nil
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	cmd.Stderr = cmd.Stdout // fold stderr into the same stream for messages
	if err := cmd.Start(); err != nil {
		return "", err
	}

	scanner := bufio.NewScanner(stdout)
	var lastLine string
	for scanner.Scan() {
		line := scanner.Text()
		lastLine = line
		if m := progressRx.FindStringSubmatch(line); m != nil {
			if pct, e := strconv.ParseFloat(m[1], 64); e == nil {
				report(pct/100, "downloading")
			}
		}
	}
	if err := cmd.Wait(); err != nil {
		if ctx.Err() == context.Canceled {
			return "", ctx.Err()
		}
		return "", fmt.Errorf("yt-dlp: %s", firstNonEmpty(lastLine, err.Error()))
	}

	produced, err := singleOutput(jobDir)
	if err != nil {
		return "", err
	}
	// Move out of the auto-cleaned jobDir into staging root so the deferred
	// RemoveAll doesn't take it before the engine delivers it.
	final := filepath.Join(y.StagingRoot, filepath.Base(produced))
	if err := os.Rename(produced, final); err != nil {
		return "", err
	}
	report(1, "done")
	return final, nil
}

// singleOutput returns the one file yt-dlp produced in dir.
func singleOutput(dir string) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	for _, e := range entries {
		if !e.IsDir() {
			return filepath.Join(dir, e.Name()), nil
		}
	}
	return "", fmt.Errorf("yt-dlp produced no file")
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
