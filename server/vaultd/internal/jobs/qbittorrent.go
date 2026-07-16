package jobs

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// TorrentRunner drives qBittorrent for one job: add the magnet under the
// user's category with a per-user staging save path, poll that torrent until
// it finishes downloading, then return the on-disk path for the engine to
// move into the library. qBittorrent keeps seeding afterward.
//
// Per-job polling (not a global /sync/maindata loop) is deliberate at family
// concurrency: the engine caps concurrent jobs, so only a couple of light
// polls run at once. If concurrency ever grows large, switch to one shared
// /sync/maindata poller (DESIGN.md notes this).
type TorrentRunner struct {
	Client   *QbitClient
	SavePath string // /srv/vault/staging/torrents
}

var _ Runner = (*TorrentRunner)(nil)

func (t *TorrentRunner) Run(ctx context.Context, job store.Job, report func(float64, string)) (string, error) {
	// Category = username keeps multi-user attribution inside one qBittorrent.
	user := job.UserID
	savePath := filepath.Join(t.SavePath, user)

	report(0, "adding to qBittorrent")
	hash, err := t.Client.Add(ctx, job.Source, user, savePath)
	if err != nil {
		return "", err
	}

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			// Canceled: remove the torrent AND its partial files.
			_ = t.Client.Delete(context.Background(), hash, true)
			return "", ctx.Err()
		case <-ticker.C:
			info, err := t.Client.Info(ctx, hash)
			if err != nil {
				return "", err
			}
			report(info.Progress, info.State)
			if info.Progress >= 1.0 || isDoneState(info.State) {
				report(1, "downloaded")
				return info.ContentPath, nil
			}
			if isErrorState(info.State) {
				return "", fmt.Errorf("qBittorrent: %s", info.State)
			}
		}
	}
}

func isDoneState(s string) bool {
	switch s {
	case "uploading", "stalledUP", "queuedUP", "forcedUP", "pausedUP", "checkingUP":
		return true
	}
	return false
}

func isErrorState(s string) bool { return s == "error" || s == "missingFiles" }

// QbitClient is a minimal qBittorrent Web API client with cookie auth. The
// compose network is not localhost, so its localhost-bypass doesn't apply —
// we log in and re-login on 403 (DESIGN.md).
type QbitClient struct {
	BaseURL  string // http://qbittorrent:8090
	Username string
	Password string

	http *http.Client
	mu   sync.Mutex
	sid  string // SID cookie
}

// NewQbitClient builds a client with a cookie jar.
func NewQbitClient(baseURL, username, password string) *QbitClient {
	return &QbitClient{
		BaseURL:  strings.TrimRight(baseURL, "/"),
		Username: username,
		Password: password,
		http:     &http.Client{Timeout: 30 * time.Second},
	}
}

func (c *QbitClient) login(ctx context.Context) error {
	form := url.Values{"username": {c.Username}, "password": {c.Password}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.BaseURL+"/api/v2/auth/login", strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Referer", c.BaseURL)
	res, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	for _, ck := range res.Cookies() {
		if ck.Name == "SID" {
			c.mu.Lock()
			c.sid = ck.Value
			c.mu.Unlock()
			return nil
		}
	}
	return fmt.Errorf("qBittorrent login failed (check credentials)")
}

// do performs an API call, logging in first if needed and retrying once on 403.
func (c *QbitClient) do(ctx context.Context, path string, form url.Values) ([]byte, error) {
	c.mu.Lock()
	sid := c.sid
	c.mu.Unlock()
	if sid == "" {
		if err := c.login(ctx); err != nil {
			return nil, err
		}
	}
	body, status, err := c.raw(ctx, path, form)
	if err != nil {
		return nil, err
	}
	if status == http.StatusForbidden {
		if err := c.login(ctx); err != nil {
			return nil, err
		}
		body, status, err = c.raw(ctx, path, form)
		if err != nil {
			return nil, err
		}
	}
	if status < 200 || status >= 300 {
		return nil, fmt.Errorf("qBittorrent %s: HTTP %d", path, status)
	}
	return body, nil
}

func (c *QbitClient) raw(ctx context.Context, path string, form url.Values) ([]byte, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+path,
		strings.NewReader(form.Encode()))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Referer", c.BaseURL)
	c.mu.Lock()
	req.AddCookie(&http.Cookie{Name: "SID", Value: c.sid})
	c.mu.Unlock()
	res, err := c.http.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer res.Body.Close()
	buf := make([]byte, 0, 4096)
	tmp := make([]byte, 4096)
	for {
		n, e := res.Body.Read(tmp)
		buf = append(buf, tmp[:n]...)
		if e != nil {
			break
		}
	}
	return buf, res.StatusCode, nil
}

// Add submits a magnet and returns its info hash (lowercased) parsed from the
// magnet URI so we can poll exactly this torrent.
func (c *QbitClient) Add(ctx context.Context, magnet, category, savePath string) (string, error) {
	form := url.Values{
		"urls":     {magnet},
		"category": {category},
		"savepath": {savePath},
		"autoTMM":  {"false"},
	}
	if _, err := c.do(ctx, "/api/v2/torrents/add", form); err != nil {
		return "", err
	}
	hash := magnetHash(magnet)
	if hash == "" {
		return "", fmt.Errorf("could not read info hash from magnet link")
	}
	return hash, nil
}

// TorrentInfo is the subset of qBittorrent's torrent record we use.
type TorrentInfo struct {
	State       string  `json:"state"`
	Progress    float64 `json:"progress"`
	ContentPath string  `json:"content_path"`
	Name        string  `json:"name"`
}

// Info returns the current record for one torrent by hash.
func (c *QbitClient) Info(ctx context.Context, hash string) (*TorrentInfo, error) {
	body, err := c.do(ctx, "/api/v2/torrents/info", url.Values{"hashes": {hash}})
	if err != nil {
		return nil, err
	}
	var list []TorrentInfo
	if err := json.Unmarshal(body, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, fmt.Errorf("torrent %s not found in qBittorrent", hash)
	}
	return &list[0], nil
}

// Delete removes a torrent (and optionally its files).
func (c *QbitClient) Delete(ctx context.Context, hash string, deleteFiles bool) error {
	_, err := c.do(ctx, "/api/v2/torrents/delete", url.Values{
		"hashes":      {hash},
		"deleteFiles": {fmt.Sprintf("%t", deleteFiles)},
	})
	return err
}

// magnetHash extracts the btih hash from a magnet URI, lowercased.
func magnetHash(magnet string) string {
	u, err := url.Parse(magnet)
	if err != nil {
		return ""
	}
	for _, xt := range u.Query()["xt"] {
		if strings.HasPrefix(xt, "urn:btih:") {
			return strings.ToLower(strings.TrimPrefix(xt, "urn:btih:"))
		}
	}
	return ""
}
