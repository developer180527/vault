package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/jobs"
)

// The torrent-client surface: a thin, AUTHORIZED façade over qBittorrent.
//
// Why this exists next to the jobs API rather than inside it: a job is work
// that completes and hands its result to the library. A torrent is a long-lived
// resource — it keeps seeding after "done", it pauses, it has a share ratio.
// Modelling one as the other would create states that mean nothing ("a paused
// upload job") and lose the ones that matter. So jobs still own the
// move-into-library pipeline; this owns torrent management. They agree because
// both key on the same info hash.
//
// THE security property, in one sentence: qBittorrent addresses torrents by
// hash and knows nothing about our users, so every mutation here resolves the
// hash to its owning category FIRST and refuses anything that isn't the
// caller's — otherwise any member could pause or delete another's downloads by
// guessing a hash.

// maxTorrentFile caps an uploaded .torrent. Real ones are KBs; a few MB is
// generous for a huge multi-file piece list and stops a silly upload.
const maxTorrentFile = 8 << 20

// torrentJSON is the wire shape. Speeds and ETA are included so the client can
// render a real transfer view without a second call.
type torrentJSON struct {
	Hash     string  `json:"hash"`
	Name     string  `json:"name"`
	State    string  `json:"state"`
	Progress float64 `json:"progress"`
	Size     int64   `json:"size"`
	DlSpeed  int64   `json:"dl_speed"`
	UpSpeed  int64   `json:"up_speed"`
	ETA      int64   `json:"eta"`
	Ratio    float64 `json:"ratio"`
	Seeds    int     `json:"seeds"`
	Peers    int     `json:"peers"`
	AddedOn  int64   `json:"added_on"`
}

func toTorrentJSON(t jobs.Torrent) torrentJSON {
	return torrentJSON{
		Hash: t.Hash, Name: t.Name, State: t.State, Progress: t.Progress,
		Size: t.Size, DlSpeed: t.DlSpeed, UpSpeed: t.UpSpeed, ETA: t.ETA,
		Ratio: t.Ratio, Seeds: t.Seeds, Peers: t.Peers, AddedOn: t.AddedOn,
	}
}

// qbit returns the torrent client, or writes 503 when torrents aren't
// configured (no qBittorrent in this deployment).
func (s *Server) qbit(w http.ResponseWriter) (*jobs.QbitClient, bool) {
	if s.torrents == nil {
		writeErr(w, http.StatusServiceUnavailable, "torrents are not configured")
		return nil, false
	}
	return s.torrents, true
}

// ownedTorrent resolves a hash and proves the caller may act on it. Admins may
// act on any torrent; everyone else only on their own category. A hash that
// exists but belongs to someone else answers 404 — not 403 — so the endpoint
// can't be used to probe which hashes exist on the server.
func (s *Server) ownedTorrent(w http.ResponseWriter, r *http.Request) (*jobs.Torrent, bool) {
	client, ok := s.qbit(w)
	if !ok {
		return nil, false
	}
	hash := strings.ToLower(strings.TrimSpace(chi.URLParam(r, "hash")))
	// Hashes are hex; anything else can't be ours and never reaches qBittorrent.
	if len(hash) < 32 || len(hash) > 64 || strings.Trim(hash, "0123456789abcdef") != "" {
		writeErr(w, http.StatusNotFound, "no such torrent")
		return nil, false
	}
	t, err := client.Get(r.Context(), hash)
	if err != nil {
		s.fail(w, r, err)
		return nil, false
	}
	p := PrincipalFrom(r.Context())
	if t == nil || (p.Role != "admin" && t.Category != p.UserID) {
		writeErr(w, http.StatusNotFound, "no such torrent")
		return nil, false
	}
	return t, true
}

// GET /v1/torrents — the caller's torrents (admins see everything).
func (s *Server) handleListTorrents(w http.ResponseWriter, r *http.Request) {
	client, ok := s.qbit(w)
	if !ok {
		return
	}
	p := PrincipalFrom(r.Context())
	category := p.UserID
	if p.Role == "admin" && r.URL.Query().Get("all") == "1" {
		category = ""
	}
	list, err := client.List(r.Context(), category)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	out := make([]torrentJSON, 0, len(list))
	for _, t := range list {
		out = append(out, toTorrentJSON(t))
	}
	writeJSON(w, http.StatusOK, map[string]any{"torrents": out})
}

// POST /v1/torrents/file — add a .torrent file (raw body).
//
// Magnets keep going through the JOB pipeline (POST /v1/jobs), which downloads
// and then files the result into the library. This endpoint is for the one
// thing that pipeline can't take: a file the user has on disk.
func (s *Server) handleAddTorrentFile(w http.ResponseWriter, r *http.Request) {
	client, ok := s.qbit(w)
	if !ok {
		return
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxTorrentFile))
	if err != nil {
		writeErr(w, http.StatusRequestEntityTooLarge, "torrent file too large")
		return
	}
	// Parse BEFORE handing anything to qBittorrent: a bad file must fail here
	// with a clear reason, not land as a broken entry someone has to clean up.
	hash, err := jobs.TorrentInfoHash(data)
	if err != nil {
		if errors.Is(err, jobs.ErrNotTorrent) || errors.Is(err, jobs.ErrNoInfoDict) {
			writeErr(w, http.StatusUnsupportedMediaType,
				"that isn't a valid .torrent file")
			return
		}
		s.fail(w, r, err)
		return
	}
	p := PrincipalFrom(r.Context())
	name := filepath.Base(r.URL.Query().Get("name"))
	if name == "" || name == "." || name == string(filepath.Separator) {
		name = "upload.torrent"
	}
	savePath := filepath.Join(s.torrentSavePath, p.UserID)
	if err := client.AddFile(r.Context(), name, data, p.UserID, savePath); err != nil {
		s.fail(w, r, err)
		return
	}
	s.log.Info("torrent file added", "user", p.Username, "hash", hash, "name", name)
	writeJSON(w, http.StatusOK, map[string]any{"hash": hash})
}

// POST /v1/torrents/{hash}/pause
func (s *Server) handlePauseTorrent(w http.ResponseWriter, r *http.Request) {
	s.torrentAction(w, r, func(c *jobs.QbitClient, hash string) error {
		return c.Pause(r.Context(), hash)
	})
}

// POST /v1/torrents/{hash}/resume
func (s *Server) handleResumeTorrent(w http.ResponseWriter, r *http.Request) {
	s.torrentAction(w, r, func(c *jobs.QbitClient, hash string) error {
		return c.Resume(r.Context(), hash)
	})
}

// POST /v1/torrents/{hash}/recheck
func (s *Server) handleRecheckTorrent(w http.ResponseWriter, r *http.Request) {
	s.torrentAction(w, r, func(c *jobs.QbitClient, hash string) error {
		return c.Recheck(r.Context(), hash)
	})
}

// DELETE /v1/torrents/{hash}?files=1 — remove, optionally with its data.
func (s *Server) handleDeleteTorrent(w http.ResponseWriter, r *http.Request) {
	withFiles := r.URL.Query().Get("files") == "1"
	s.torrentAction(w, r, func(c *jobs.QbitClient, hash string) error {
		return c.Delete(r.Context(), hash, withFiles)
	})
}

// torrentAction runs [do] against a torrent the caller is proven to own.
func (s *Server) torrentAction(w http.ResponseWriter, r *http.Request,
	do func(*jobs.QbitClient, string) error) {
	t, ok := s.ownedTorrent(w, r)
	if !ok {
		return
	}
	if err := do(s.torrents, t.Hash); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// GET /v1/torrents/transfer — global speeds and limits.
func (s *Server) handleTransferInfo(w http.ResponseWriter, r *http.Request) {
	client, ok := s.qbit(w)
	if !ok {
		return
	}
	t, err := client.Transfer(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"dl_speed": t.DlSpeed, "up_speed": t.UpSpeed,
		"dl_limit": t.DlLimit, "up_limit": t.UpLimit,
		"alt_speed": t.AltSpeedOn,
	})
}

// PUT /v1/torrents/limits {dl_limit, up_limit} — bytes/sec, 0 = unlimited.
// ADMIN ONLY: qBittorrent has a single global pipe, so one member throttling it
// would silently throttle the whole household.
func (s *Server) handleSetTorrentLimits(w http.ResponseWriter, r *http.Request) {
	client, ok := s.qbit(w)
	if !ok {
		return
	}
	var req struct {
		DlLimit *int64 `json:"dl_limit"`
		UpLimit *int64 `json:"up_limit"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	cur, err := client.Transfer(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	// Absent fields keep their current value, so setting one limit can't
	// silently clear the other.
	down, up := cur.DlLimit, cur.UpLimit
	if req.DlLimit != nil {
		down = *req.DlLimit
	}
	if req.UpLimit != nil {
		up = *req.UpLimit
	}
	if down < 0 || up < 0 {
		writeErr(w, http.StatusBadRequest, "limits cannot be negative")
		return
	}
	if err := client.SetSpeedLimits(r.Context(), down, up); err != nil {
		s.fail(w, r, err)
		return
	}
	p := PrincipalFrom(r.Context())
	s.log.Info("torrent speed limits set", "by", p.Username,
		"dl", strconv.FormatInt(down, 10), "up", strconv.FormatInt(up, 10))
	writeJSON(w, http.StatusOK, map[string]any{"dl_limit": down, "up_limit": up})
}
