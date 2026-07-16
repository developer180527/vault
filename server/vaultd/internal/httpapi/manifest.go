package httpapi

import (
	"net/http"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// handleManifest returns the caller's capability manifest in exactly the
// shape the Flutter client's CapabilityManifest parses. This endpoint IS the
// mock→real switch: the client renders navigation from nothing else.
//
// GET /v1/manifest  (authenticated)
func (s *Server) handleManifest(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())

	caps := map[string]map[string]any{}
	if p.Role == "admin" {
		// Admins hold every service with every action; no rows needed.
		for _, svc := range store.KnownServices {
			caps[svc] = map[string]any{"actions": store.KnownActions}
		}
	} else {
		grants, err := s.store.Read().GrantsForUser(r.Context(), p.UserID)
		if err != nil {
			s.fail(w, r, err)
			return
		}
		for svc, actions := range grants {
			caps[svc] = map[string]any{"actions": actions}
		}
	}

	// Suggested dock order: the canonical four, filtered to what's granted.
	pinned := []string{}
	for _, svc := range []string{"media", "files", "music", "torrent"} {
		if _, ok := caps[svc]; ok {
			pinned = append(pinned, svc)
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"device_id":      p.DeviceID,
		"profile_id":     p.UserID,
		"username":       p.Username,
		"capabilities":   caps,
		"default_pinned": pinned,
	})
}
