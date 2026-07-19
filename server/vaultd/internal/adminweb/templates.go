package adminweb

import (
	"embed"
	"fmt"
	"html/template"
	"net/http"
	"time"
)

//go:embed templates/*.html
var templateFS embed.FS

// funcs are the display helpers pages lean on (bytes, relative times).
var funcs = template.FuncMap{
	// fmtBytes: humanized size; negative = unavailable → em dash.
	"fmtBytes": func(n int64) string {
		if n < 0 {
			return "—"
		}
		const unit = 1024
		if n < unit {
			return fmt.Sprintf("%d B", n)
		}
		div, exp := int64(unit), 0
		for m := n / unit; m >= unit; m /= unit {
			div *= unit
			exp++
		}
		return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "KMGTPE"[exp])
	},
	// durationMin: milliseconds → whole minutes, for movie runtimes.
	"durationMin": func(ms int64) int64 { return ms / 60000 },
	// ago: compact relative time for feeds. Accepts time.Time OR a unix
	// seconds int64 (store rows carry raw integers); zero = "never".
	"ago": func(v any) string {
		var t time.Time
		switch x := v.(type) {
		case time.Time:
			t = x
		case int64:
			if x == 0 {
				return "never"
			}
			t = time.Unix(x, 0)
		case int:
			if x == 0 {
				return "never"
			}
			t = time.Unix(int64(x), 0)
		default:
			return "—"
		}
		d := time.Since(t)
		switch {
		case d < time.Minute:
			return "just now"
		case d < time.Hour:
			return fmt.Sprintf("%dm ago", int(d.Minutes()))
		case d < 24*time.Hour:
			return fmt.Sprintf("%dh ago", int(d.Hours()))
		default:
			return t.Format("Jan 2 15:04")
		}
	},
}

// Parsed once at init; template execution is per-request. base.html defines
// the shell, each page fills the "content" block.
var templates = template.Must(
	template.New("").Funcs(funcs).ParseFS(templateFS, "templates/*.html"))

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
