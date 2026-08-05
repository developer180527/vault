package jobs

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// Management operations over qBittorrent — the surface a real torrent client
// needs, beyond the add-and-poll the job runner uses.
//
// Everything here is deliberately category-scoped at the CALLER's insistence:
// qBittorrent addresses torrents by hash and has no notion of our users, so
// vaultd is the only thing standing between one household member and another's
// downloads. See httpapi/torrents.go, which resolves a hash to its owner before
// any mutation reaches these methods.

// Torrent is the full record the client UI renders. Field names mirror
// qBittorrent's API so the mapping stays obvious.
type Torrent struct {
	Hash     string  `json:"hash"`
	Name     string  `json:"name"`
	State    string  `json:"state"`
	Progress float64 `json:"progress"` // 0..1
	Size     int64   `json:"size"`
	Done     int64   `json:"completed"`
	DlSpeed  int64   `json:"dlspeed"` // bytes/sec
	UpSpeed  int64   `json:"upspeed"`
	ETA      int64   `json:"eta"` // seconds; 8640000 = unknown
	Ratio    float64 `json:"ratio"`
	Seeds    int     `json:"num_seeds"`
	Peers    int     `json:"num_leechs"`
	Category string  `json:"category"`
	SavePath string  `json:"save_path"`
	AddedOn  int64   `json:"added_on"`
}

// List returns torrents in [category]. An empty category lists everything —
// only ever used for admin views; per-user calls always pass one.
func (c *QbitClient) List(ctx context.Context, category string) ([]Torrent, error) {
	form := url.Values{}
	if category != "" {
		form.Set("category", category)
	}
	body, err := c.do(ctx, "/api/v2/torrents/info", form)
	if err != nil {
		return nil, err
	}
	var list []Torrent
	if err := json.Unmarshal(body, &list); err != nil {
		return nil, fmt.Errorf("qBittorrent list: %w", err)
	}
	return list, nil
}

// Get returns one torrent by hash, or nil when qBittorrent doesn't have it.
// Returning (nil, nil) rather than an error keeps "unknown hash" — the case
// authorization must handle — distinct from "qBittorrent is unreachable".
func (c *QbitClient) Get(ctx context.Context, hash string) (*Torrent, error) {
	body, err := c.do(ctx, "/api/v2/torrents/info",
		url.Values{"hashes": {strings.ToLower(hash)}})
	if err != nil {
		return nil, err
	}
	var list []Torrent
	if err := json.Unmarshal(body, &list); err != nil {
		return nil, fmt.Errorf("qBittorrent get: %w", err)
	}
	if len(list) == 0 {
		return nil, nil
	}
	return &list[0], nil
}

// AddFile submits a .torrent file. The caller supplies the info hash (derived
// from the same bytes via [TorrentInfoHash]) because qBittorrent's add endpoint
// answers only "Ok." — deriving it locally avoids racing a list-diff against
// concurrent adds.
func (c *QbitClient) AddFile(ctx context.Context, filename string, data []byte,
	category, savePath string) error {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	part, err := mw.CreateFormFile("torrents", filename)
	if err != nil {
		return err
	}
	if _, err := part.Write(data); err != nil {
		return err
	}
	for k, v := range map[string]string{
		"category": category,
		"savepath": savePath,
		"autoTMM":  "false",
	} {
		if err := mw.WriteField(k, v); err != nil {
			return err
		}
	}
	if err := mw.Close(); err != nil {
		return err
	}
	return c.postRaw(ctx, "/api/v2/torrents/add", mw.FormDataContentType(), buf.Bytes())
}

// postRaw sends a non-form body (multipart), logging in first and retrying once
// on 403 — mirroring `do`'s session handling.
func (c *QbitClient) postRaw(ctx context.Context, path, contentType string, body []byte) error {
	send := func() (int, error) {
		c.mu.Lock()
		sid, sidName := c.sid, c.sidName
		c.mu.Unlock()
		req, err := http.NewRequestWithContext(ctx, http.MethodPost,
			c.BaseURL+path, bytes.NewReader(body))
		if err != nil {
			return 0, err
		}
		req.Header.Set("Content-Type", contentType)
		req.Header.Set("Referer", c.BaseURL)
		if sid != "" && sidName != "" {
			req.AddCookie(&http.Cookie{Name: sidName, Value: sid})
		}
		res, err := c.http.Do(req)
		if err != nil {
			return 0, err
		}
		defer res.Body.Close()
		_, _ = io.Copy(io.Discard, res.Body)
		return res.StatusCode, nil
	}

	c.mu.Lock()
	needLogin := c.sid == ""
	c.mu.Unlock()
	if needLogin {
		if err := c.login(ctx); err != nil {
			return err
		}
	}
	code, err := send()
	if err != nil {
		return err
	}
	if code == http.StatusForbidden {
		if err := c.login(ctx); err != nil {
			return err
		}
		if code, err = send(); err != nil {
			return err
		}
	}
	if code != http.StatusOK {
		return fmt.Errorf("qBittorrent %s: HTTP %d", path, code)
	}
	return nil
}

// Pause stops a torrent; Resume restarts it. qBittorrent renamed these
// endpoints in 5.x (pause→stop, resume→start), so both spellings are tried —
// otherwise an upgrade silently breaks the buttons.
func (c *QbitClient) Pause(ctx context.Context, hash string) error {
	return c.tryEither(ctx, "/api/v2/torrents/stop", "/api/v2/torrents/pause", hash)
}

func (c *QbitClient) Resume(ctx context.Context, hash string) error {
	return c.tryEither(ctx, "/api/v2/torrents/start", "/api/v2/torrents/resume", hash)
}

func (c *QbitClient) tryEither(ctx context.Context, primary, fallback, hash string) error {
	form := url.Values{"hashes": {strings.ToLower(hash)}}
	if _, err := c.do(ctx, primary, form); err == nil {
		return nil
	}
	_, err := c.do(ctx, fallback, form)
	return err
}

// Recheck re-verifies a torrent's data against its pieces.
func (c *QbitClient) Recheck(ctx context.Context, hash string) error {
	_, err := c.do(ctx, "/api/v2/torrents/recheck",
		url.Values{"hashes": {strings.ToLower(hash)}})
	return err
}

// Transfer is qBittorrent's global transfer state.
type Transfer struct {
	DlSpeed      int64 `json:"dl_info_speed"`
	UpSpeed      int64 `json:"up_info_speed"`
	DlLimit      int64 `json:"dl_rate_limit"`
	UpLimit      int64 `json:"up_rate_limit"`
	AltSpeedOn   bool  `json:"use_alt_speed_limits"`
	DlTotalBytes int64 `json:"dl_info_data"`
	UpTotalBytes int64 `json:"up_info_data"`
}

func (c *QbitClient) Transfer(ctx context.Context) (*Transfer, error) {
	body, err := c.do(ctx, "/api/v2/transfer/info", nil)
	if err != nil {
		return nil, err
	}
	var t Transfer
	if err := json.Unmarshal(body, &t); err != nil {
		return nil, fmt.Errorf("qBittorrent transfer info: %w", err)
	}
	return &t, nil
}

// SetSpeedLimits sets the GLOBAL rate limits in bytes/sec (0 = unlimited).
// Global, not per-user: qBittorrent has one pipe, and pretending otherwise
// would be a lie in the UI. Admin-only at the HTTP layer.
func (c *QbitClient) SetSpeedLimits(ctx context.Context, down, up int64) error {
	if down < 0 || up < 0 {
		return fmt.Errorf("speed limits cannot be negative")
	}
	if _, err := c.do(ctx, "/api/v2/transfer/setDownloadLimit",
		url.Values{"limit": {strconv.FormatInt(down, 10)}}); err != nil {
		return err
	}
	_, err := c.do(ctx, "/api/v2/transfer/setUploadLimit",
		url.Values{"limit": {strconv.FormatInt(up, 10)}})
	return err
}

// TorrentFile is one entry in a torrent's file list.
type TorrentFile struct {
	Index    int     `json:"index"`
	Name     string  `json:"name"` // path relative to the torrent root
	Size     int64   `json:"size"`
	Progress float64 `json:"progress"`
	Priority int     `json:"priority"` // 0 = don't download
}

// Files lists a torrent's contents. Available as soon as metadata resolves,
// which is what lets the UI ask "which of these do you actually want?" before
// gigabytes have moved.
func (c *QbitClient) Files(ctx context.Context, hash string) ([]TorrentFile, error) {
	body, err := c.do(ctx, "/api/v2/torrents/files",
		url.Values{"hash": {strings.ToLower(hash)}})
	if err != nil {
		return nil, err
	}
	var list []TorrentFile
	if err := json.Unmarshal(body, &list); err != nil {
		return nil, fmt.Errorf("qBittorrent files: %w", err)
	}
	// Older builds omit `index`; positional order is the index in that case.
	for i := range list {
		if list[i].Index == 0 && i != 0 {
			list[i].Index = i
		}
	}
	return list, nil
}

// SetFilePriority marks files wanted (1) or unwanted (0).
//
// Treat this as a BANDWIDTH HINT, not a guarantee. qBittorrent still fetches
// pieces that straddle a wanted/unwanted boundary, and has a long history of
// quietly writing unwanted files anyway — so vaultd verifies what actually
// landed rather than trusting the priority took.
func (c *QbitClient) SetFilePriority(ctx context.Context, hash string, indices []int, priority int) error {
	if len(indices) == 0 {
		return nil
	}
	ids := make([]string, len(indices))
	for i, n := range indices {
		ids[i] = strconv.Itoa(n)
	}
	_, err := c.do(ctx, "/api/v2/torrents/filePrio", url.Values{
		"hash":     {strings.ToLower(hash)},
		"id":       {strings.Join(ids, "|")},
		"priority": {strconv.Itoa(priority)},
	})
	return err
}
