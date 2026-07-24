package adminweb

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// Phase 2 (Activity/audit) + Phase 3 (System) + the catalog upload surface
// (ADMIN.md §6 D/E/F, §10). Everything here sits behind requireAdmin.

// audit appends one append-only activity row (ADMIN.md §4). Best-effort BY
// DESIGN: the mutation already happened, so an audit-write failure is logged,
// never surfaced as an action failure.
func (s *Server) audit(r *http.Request, action, kind, id, summary string) {
	e := store.AuditEntry{
		ActorUser:  userFrom(r).Username,
		Action:     action,
		TargetKind: kind,
		TargetID:   id,
		Summary:    summary,
		RemoteAddr: r.RemoteAddr,
	}
	if err := s.store.Write().InsertAudit(r.Context(), e); err != nil {
		s.log.Error("audit write failed", "action", action, "err", err)
	}
}

// ---- Catalog: cover-art upload for one track ----

const artMaxBytes = 10 << 20 // 10 MiB

func (s *Server) handleTrackArtUpload(w http.ResponseWriter, r *http.Request) {
	t, ok := s.targetTrack(w, r)
	if !ok {
		return
	}
	back := "/catalog/" + t.ID
	r.Body = http.MaxBytesReader(w, r.Body, artMaxBytes)
	if err := r.ParseMultipartForm(artMaxBytes); err != nil {
		redirectMsg(w, r, back, "Image too large (10 MB max).")
		return
	}
	defer func() { _ = r.MultipartForm.RemoveAll() }()
	file, _, err := r.FormFile("art")
	if err != nil {
		redirectMsg(w, r, back, "Pick an image file.")
		return
	}
	defer file.Close()
	data := make([]byte, 0, 1<<20)
	buf := make([]byte, 64<<10)
	for {
		n, rerr := file.Read(buf)
		data = append(data, buf[:n]...)
		if rerr != nil {
			break
		}
	}
	if !strings.HasPrefix(http.DetectContentType(data), "image/") {
		redirectMsg(w, r, back, "That file isn't an image.")
		return
	}
	if err := s.music.SetCatalogArtOverride(t.ID, data); err != nil {
		redirectMsg(w, r, back, "Storing the artwork failed.")
		return
	}
	if !t.HasArt {
		_ = s.store.Write().SetCatalogHasArt(r.Context(), t.ID, true)
	}
	s.audit(r, "track.art", "track", t.ID, "cover art replaced: "+t.Title)
	// Tell connected apps: they re-list, pick up the new art_version, and the
	// `?v=`-keyed cover URL busts every client image cache.
	s.changes.Bump("music")
	redirectMsg(w, r, back, "Artwork updated — it overrides the file's embedded art.")
}

// ---- Activity (Phase 2) ----

func (s *Server) handleActivity(w http.ResponseWriter, r *http.Request) {
	entries, err := s.store.Read().ListAudit(r.Context(), 200)
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, "Could not read the audit log.")
		return
	}
	s.render(w, "activity.html", map[string]any{
		"User": userFrom(r), "Active": "activity",
		"Entries": entries, "Msg": r.URL.Query().Get("msg"),
	})
}

// ---- System (Phase 3, metrics option 1: read-only /proc + statfs) ----

type sysMetrics struct {
	Load     string // 1/5/15 min
	MemUsed  int64  // bytes; -1 = unavailable
	MemTotal int64
	Uptime   string // humanized; "" = unavailable
	DiskFree int64  // bytes on the data volume; -1 = unavailable
	DiskSize int64
	DBBytes  int64 // -1 = unavailable

	// Photo store volume (the HDD pool) — only shown when it's a separate
	// filesystem from the data volume. -1 = no separate volume.
	PhotoFree int64
	PhotoSize int64

	Users, Admins, Devices, Tracks, Listens int
	PhotoCount                              int
	PhotoBytes                              int64

	GoVersion, Revision, BuildTime string
}

func (s *Server) collectMetrics(r *http.Request) sysMetrics {
	m := sysMetrics{MemUsed: -1, MemTotal: -1, DiskFree: -1, DiskSize: -1,
		DBBytes: -1, GoVersion: runtime.Version()}

	// Host CPU/RAM/uptime via /proc — present in the Linux container; absent
	// on a dev Mac, where the fields just render as "—". Read-only by design
	// (ADMIN.md §8 option 1).
	if b, err := os.ReadFile("/proc/loadavg"); err == nil {
		if f := strings.Fields(string(b)); len(f) >= 3 {
			m.Load = f[0] + " · " + f[1] + " · " + f[2]
		}
	}
	if b, err := os.ReadFile("/proc/meminfo"); err == nil {
		var totalKB, availKB int64
		for _, ln := range strings.Split(string(b), "\n") {
			f := strings.Fields(ln)
			if len(f) < 2 {
				continue
			}
			v, _ := strconv.ParseInt(f[1], 10, 64)
			switch f[0] {
			case "MemTotal:":
				totalKB = v
			case "MemAvailable:":
				availKB = v
			}
		}
		if totalKB > 0 {
			m.MemTotal = totalKB << 10
			m.MemUsed = (totalKB - availKB) << 10
		}
	}
	if b, err := os.ReadFile("/proc/uptime"); err == nil {
		if f := strings.Fields(string(b)); len(f) >= 1 {
			if secs, err := strconv.ParseFloat(f[0], 64); err == nil {
				m.Uptime = humanDuration(time.Duration(secs) * time.Second)
			}
		}
	}

	// Data volume free space (works on Linux and macOS).
	m.PhotoFree, m.PhotoSize = -1, -1
	var st syscall.Statfs_t
	if err := syscall.Statfs(s.music.DataRoot, &st); err == nil {
		m.DiskFree = int64(st.Bavail) * int64(st.Bsize) //nolint:unconvert
		m.DiskSize = int64(st.Blocks) * int64(st.Bsize) //nolint:unconvert
	}
	// The photo store (HDD pool) gets its own card when it's a different
	// filesystem — same fsid as the data volume means one disk, one card.
	if s.photosRoot != "" {
		var pst syscall.Statfs_t
		if err := syscall.Statfs(s.photosRoot, &pst); err == nil &&
			pst.Fsid != st.Fsid {
			m.PhotoFree = int64(pst.Bavail) * int64(pst.Bsize) //nolint:unconvert
			m.PhotoSize = int64(pst.Blocks) * int64(pst.Bsize) //nolint:unconvert
		}
	}
	if fi, err := os.Stat(filepath.Join(
		s.music.DataRoot, "system", "db", "vault.db")); err == nil {
		m.DBBytes = fi.Size()
	}

	ctx := r.Context()
	m.Users, _ = s.store.Read().CountUsers(ctx)
	m.Admins, _ = s.store.Read().CountActiveAdmins(ctx)
	if devs, err := s.store.Read().ListDevices(ctx, ""); err == nil {
		m.Devices = len(devs)
	}
	if tracks, err := s.store.Read().CatalogTracks(ctx); err == nil {
		m.Tracks = len(tracks)
	}
	m.Listens, _ = s.store.Read().CountListens(ctx)
	m.PhotoCount, m.PhotoBytes, _ = s.store.Read().CountAllPhotos(ctx)

	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, kv := range bi.Settings {
			switch kv.Key {
			case "vcs.revision":
				if len(kv.Value) >= 9 {
					m.Revision = kv.Value[:9]
				} else {
					m.Revision = kv.Value
				}
			case "vcs.time":
				m.BuildTime = kv.Value
			}
		}
	}
	return m
}

func (s *Server) handleSystem(w http.ResponseWriter, r *http.Request) {
	s.render(w, "system.html", map[string]any{
		"User": userFrom(r), "Active": "system",
		"M": s.collectMetrics(r), "Msg": r.URL.Query().Get("msg"),
	})
}

func humanDuration(d time.Duration) string {
	days := int(d.Hours()) / 24
	hours := int(d.Hours()) % 24
	mins := int(d.Minutes()) % 60
	switch {
	case days > 0:
		return fmt.Sprintf("%dd %dh", days, hours)
	case hours > 0:
		return fmt.Sprintf("%dh %dm", hours, mins)
	default:
		return fmt.Sprintf("%dm", mins)
	}
}
