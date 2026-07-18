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

	s.render(w, "insights.html", map[string]any{
		"User": userFrom(r), "Active": "insights",
		"Window":    insightsWindowDays,
		"Tracks":    trackRows,
		"Artists":   artistRows,
		"Listeners": listenerRows,
		"Days":      dayRows,
		"Recent":    recent,
		"Msg":       r.URL.Query().Get("msg"),
	})
}
