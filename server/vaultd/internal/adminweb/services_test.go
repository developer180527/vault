package adminweb

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestProbeTreatsAuthRefusalAsUp(t *testing.T) {
	// These services are SUPPOSED to refuse an unauthenticated caller, so a
	// 401/403 proves they're alive. Reporting them as down would send an admin
	// chasing an outage that isn't happening.
	for _, code := range []int{200, 302, 401, 403, 404, 500} {
		srv := httptest.NewServer(http.HandlerFunc(
			func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(code)
			}))
		up, detail := probe(t.Context(), srv.URL)
		if !up {
			t.Fatalf("HTTP %d reported down: %s", code, detail)
		}
		srv.Close()
	}
}

func TestProbeReportsUnreachable(t *testing.T) {
	// A closed port must read as down, with a reason rather than a bare flag.
	srv := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {}))
	dead := srv.URL
	srv.Close()

	up, detail := probe(t.Context(), dead)
	if up {
		t.Fatal("a closed port reported as reachable")
	}
	if detail == "" {
		t.Fatal("no reason given for an unreachable service")
	}
}

func TestProbeRejectsMalformedURL(t *testing.T) {
	for _, bad := range []string{"", "not a url", "/relative/only", "://x"} {
		if up, _ := probe(t.Context(), bad); up {
			t.Fatalf("malformed URL %q reported as reachable", bad)
		}
	}
}

// The page must render even when a service has no URL configured, and must
// never leak the compose-internal address as a browser link.
func TestServicesPageHandlesMissingConfig(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")
	cookie := e.login(t)

	req := httptest.NewRequest("GET", "/services", nil)
	req.AddCookie(cookie)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("/services = %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Services") {
		t.Fatal("services page did not render")
	}
	if strings.Contains(body, "http://qbittorrent:8090") {
		t.Fatal("compose-internal qBittorrent URL leaked into the page")
	}
	if !strings.Contains(body, "Not configured") {
		t.Fatal("an unconfigured service should say so")
	}
}
