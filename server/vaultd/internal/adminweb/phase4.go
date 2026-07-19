// Phase 4 (ADMIN.md): listen analytics — the Insights page. Read-only
// aggregation over the raw listens log; bars are server-computed CSS widths,
// keeping the panel's zero-JavaScript invariant.
package adminweb

import (
	"net/http"
)

// barRow is one pre-computed horizontal bar (label, value, width %).
type barRow struct {
	Label string
	Sub   string
	Plays int
	Mins  int64
	Pct   int // 4..100, of the row maximum
}

func pct(v, max int) int {
	if max <= 0 {
		return 0
	}
	p := v * 100 / max
	if p < 4 {
		return 4 // a sliver stays visible
	}
	return p
}

const insightsWindowDays = 30

func (s *Server) handleInsights(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	read := s.store.Read()

	tracks, err := read.TopTracks(ctx, insightsWindowDays, 15)
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, err.Error())
		return
	}
	artists, err := read.TopArtists(ctx, insightsWindowDays, 10)
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, err.Error())
		return
	}
	listeners, err := read.TopListeners(ctx, insightsWindowDays, 10)
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, err.Error())
		return
	}
	days, err := read.ListensPerDay(ctx, 14)
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, err.Error())
		return
	}
	recent, err := read.RecentListens(ctx, 25)
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, err.Error())
		return
	}

	// Photo backup analytics — who's protected, how the store grows.
	photoUsers, err := read.PhotoBackupByUser(ctx)
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, err.Error())
		return
	}
	photoDays, err := read.PhotosPerDay(ctx, 14)
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, err.Error())
		return
	}
	photoYears, err := read.PhotosByYear(ctx)
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, err.Error())
		return
	}
	kinds, err := read.PhotoKindTotals(ctx)
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, err.Error())
		return
	}

	maxOf := func(n func(i int) int, count int) int {
		m := 0
		for i := 0; i < count; i++ {
			if v := n(i); v > m {
				m = v
			}
		}
		return m
	}

	trackMax := maxOf(func(i int) int { return tracks[i].Plays }, len(tracks))
	trackRows := make([]barRow, len(tracks))
	for i, t := range tracks {
		trackRows[i] = barRow{Label: t.Title, Sub: t.Artist, Plays: t.Plays,
			Mins: t.Ms / 60000, Pct: pct(t.Plays, trackMax)}
	}
	artistMax := maxOf(func(i int) int { return artists[i].Plays }, len(artists))
	artistRows := make([]barRow, len(artists))
	for i, a := range artists {
		artistRows[i] = barRow{Label: a.Artist, Plays: a.Plays,
			Mins: a.Ms / 60000, Pct: pct(a.Plays, artistMax)}
	}
	listenerMax := maxOf(func(i int) int { return listeners[i].Plays }, len(listeners))
	listenerRows := make([]barRow, len(listeners))
	for i, l := range listeners {
		listenerRows[i] = barRow{Label: l.Username, Plays: l.Plays,
			Mins: l.Ms / 60000, Pct: pct(l.Plays, listenerMax)}
	}
	dayMax := maxOf(func(i int) int { return days[i].Plays }, len(days))
	type dayRow struct {
		Day   string
		Plays int
		Pct   int
	}
	dayRows := make([]dayRow, len(days))
	for i, d := range days {
		dayRows[i] = dayRow{Day: d.Day, Plays: d.Plays, Pct: pct(d.Plays, dayMax)}
	}

	// Photo bars: users by bytes, upload activity, capture-year spread.
	userBytesMax := 0
	for _, u := range photoUsers {
		if int(u.Bytes>>20) > userBytesMax {
			userBytesMax = int(u.Bytes >> 20)
		}
	}
	photoUserRows := make([]barRow, len(photoUsers))
	for i, u := range photoUsers {
		photoUserRows[i] = barRow{Label: u.Username, Plays: u.Count,
			Mins: u.Bytes >> 20, Pct: pct(int(u.Bytes>>20), userBytesMax)}
	}
	photoDayMax := maxOf(func(i int) int { return photoDays[i].Plays }, len(photoDays))
	type dayBar struct {
		Day   string
		Plays int
		Pct   int
	}
	photoDayRows := make([]dayBar, len(photoDays))
	for i, d := range photoDays {
		photoDayRows[i] = dayBar{Day: d.Day, Plays: d.Plays,
			Pct: pct(d.Plays, photoDayMax)}
	}
	photoYearMax := maxOf(func(i int) int { return photoYears[i].Plays }, len(photoYears))
	photoYearRows := make([]dayBar, len(photoYears))
	for i, y := range photoYears {
		photoYearRows[i] = dayBar{Day: y.Day, Plays: y.Plays,
			Pct: pct(y.Plays, photoYearMax)}
	}

	// Summary KPIs for the header strip — cheap sums over what we already have.
	totalPlays := 0
	for _, l := range listeners {
		totalPlays += l.Plays
	}
	photoBytes := kinds["photo"].Bytes + kinds["video"].Bytes

	s.render(w, "insights.html", map[string]any{
		"User": userFrom(r), "Active": "insights",
		"Window":    insightsWindowDays,
		"Tracks":    trackRows,
		"Artists":   artistRows,
		"Listeners": listenerRows,
		"Days":      dayRows,
		"Recent":    recent,
		"PhotoUsers": photoUserRows,
		"PhotoDays":  photoDayRows,
		"PhotoYears": photoYearRows,
		"PhotoCount": kinds["photo"].Count, "PhotoBytes": kinds["photo"].Bytes,
		"VideoCount": kinds["video"].Count, "VideoBytes": kinds["video"].Bytes,
		// Header summary.
		"SumPlays":      totalPlays,
		"SumListeners":  len(listeners),
		"SumMedia":      kinds["photo"].Count + kinds["video"].Count,
		"SumMediaBytes": photoBytes,
		"HasMusic":      len(trackRows) > 0,
		"HasPhotos":     len(photoUserRows) > 0,
		"Msg":           r.URL.Query().Get("msg"),
	})
}
