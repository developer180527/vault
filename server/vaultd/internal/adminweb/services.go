package adminweb

import (
	"context"
	"net/http"
	"net/url"
	"sync"
	"time"
)

// The Services page: one place to find the other pieces of the stack, with a
// live reachability check.
//
// These are LINKS, not a reverse proxy, and that is a deliberate choice.
// Pocket ID and qBittorrent are single-page apps with their own sessions, CSRF
// handling, absolute asset paths and websockets; serving them under a
// /services/... prefix breaks all four in ways that are miserable to debug.
// Worse, proxying them behind THIS panel's cookie would let an admin-panel
// session act on those services without their own login — quietly widening the
// blast radius of one stolen cookie. Both already have their own
// tailnet-gated, admin-only entrances; the useful thing to add is a signpost
// and a health check, not a tunnel.
//
// The reachability probe runs SERVER-side (vaultd shares the compose network),
// so it answers "is the service actually up?" rather than "can my browser
// route to it?" — which is the question an admin is asking when something
// looks broken.

// serviceLink is one row on the page.
type serviceLink struct {
	Name    string
	Purpose string
	URL     string // browser-reachable; empty = not configured
	Up      bool
	Detail  string // why it's down, or a note when there's no URL
}

// probeTimeout keeps a wedged service from stalling the whole page. The
// probes run concurrently, so the page costs at most this long.
const probeTimeout = 3 * time.Second

func (s *Server) handleServices(w http.ResponseWriter, r *http.Request) {
	links := []serviceLink{
		{
			Name:    "Pocket ID",
			Purpose: "Identity — passkeys, users, OIDC clients.",
			URL:     s.pocketIDURL,
		},
		{
			Name:    "qBittorrent",
			Purpose: "The torrent engine behind the Torrent service.",
			URL:     s.qbitExternalURL,
		},
	}

	// Probe concurrently: two sequential 3s timeouts would make a page with
	// one dead service feel broken itself.
	var wg sync.WaitGroup
	for i := range links {
		if links[i].URL == "" {
			links[i].Detail = "No external URL configured for this deployment."
			continue
		}
		wg.Add(1)
		go func(l *serviceLink) {
			defer wg.Done()
			l.Up, l.Detail = probe(r.Context(), l.URL)
		}(&links[i])
	}
	wg.Wait()

	s.render(w, "services.html", map[string]any{
		"User": userFrom(r), "Active": "services",
		"Links": links, "Msg": r.URL.Query().Get("msg"),
	})
}

// probe reports whether a service answers at all. Any HTTP response — including
// 401/403 — means it's UP: these services are supposed to refuse an
// unauthenticated caller, so a refusal is proof of life, not a fault.
func probe(ctx context.Context, raw string) (bool, string) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return false, "Configured URL is not valid."
	}
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, raw, nil)
	if err != nil {
		return false, err.Error()
	}
	// Don't follow redirects: a login redirect is still "up", and chasing it
	// costs another round trip.
	client := &http.Client{
		Timeout: probeTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	res, err := client.Do(req)
	if err != nil {
		return false, "Not responding: " + err.Error()
	}
	defer res.Body.Close()
	return true, ""
}
