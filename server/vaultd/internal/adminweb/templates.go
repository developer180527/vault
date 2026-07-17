package adminweb

import (
	"embed"
	"html/template"
	"net/http"
)

//go:embed templates/*.html
var templateFS embed.FS

// Parsed once at init; template execution is per-request. base.html defines
// the shell, each page fills the "content" block.
var templates = template.Must(template.ParseFS(templateFS, "templates/*.html"))

func (s *Server) render(w http.ResponseWriter, page string, data map[string]any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := templates.ExecuteTemplate(w, page, data); err != nil {
		s.log.Error("template", "page", page, "err", err)
	}
}

func (s *Server) renderError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(code)
	_ = templates.ExecuteTemplate(w, "error.html", map[string]any{
		"Message": msg,
	})
}
