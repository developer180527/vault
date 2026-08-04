package adminweb

import "strings"

// Multi-value fields (artist, genre) are stored comma-joined — the format the
// CLIENT already splits on to group Home by artist, so this is purely an
// editing improvement over unchanged storage.
//
// The panel is zero-JavaScript, so the usual "type, press Enter, get a chip"
// widget isn't available. Instead this leans on a native browser behaviour:
// pressing Enter in a text input SUBMITS THE FORM. The server tokenizes and
// re-renders the chips. One round-trip per tag, which over a tailnet is a few
// milliseconds — indistinguishable from a local widget, and nothing to break.

// splitTags parses a stored comma-joined field into individual values,
// trimming blanks. "Asha Bhosle, Mohammed Rafi" → ["Asha Bhosle", "Mohammed Rafi"].
func splitTags(s string) []string {
	out := []string{}
	for _, p := range strings.Split(s, ",") {
		if v := strings.TrimSpace(p); v != "" {
			out = append(out, v)
		}
	}
	return out
}

// joinTags renders values back to storage form.
func joinTags(v []string) string { return strings.Join(v, ", ") }

// addTag appends one or more values (the input itself may be comma-separated,
// so pasting the old "A, B" format still does the right thing). Duplicates are
// ignored case-insensitively; order is preserved.
func addTag(values []string, input string) []string {
	for _, v := range splitTags(input) {
		dup := false
		for _, existing := range values {
			if strings.EqualFold(existing, v) {
				dup = true
				break
			}
		}
		if !dup {
			values = append(values, v)
		}
	}
	return values
}

// removeTag drops one value (case-insensitive match).
func removeTag(values []string, victim string) []string {
	out := make([]string, 0, len(values))
	for _, v := range values {
		if !strings.EqualFold(v, victim) {
			out = append(out, v)
		}
	}
	return out
}

// tagField is what the "tagfield" template partial renders.
type tagField struct {
	Name   string // form field base name, e.g. "artist"
	Label  string
	Values []string
	Hint   string
	Focus  bool // autofocus the add box (set right after an add/remove)
}

// tagFocusFrom reports which tag field this submit touched (added to or
// removed from), so the redirect can put the cursor back there. Empty when the
// submit was a plain Save.
func tagFocusFrom(form map[string][]string) string {
	for _, name := range []string{"artist", "genre"} {
		if v := form["add_"+name]; len(v) > 0 && strings.TrimSpace(v[0]) != "" {
			return name
		}
		if v := form["remove_"+name]; len(v) > 0 && v[0] != "" {
			return name
		}
	}
	return ""
}

// resolveTags applies this request's add/remove to the submitted chip list and
// returns the storage string. `values` come from the repeated hidden inputs,
// so the form — what the admin actually sees — is the source of truth.
func resolveTags(form map[string][]string, name string) string {
	values := append([]string{}, form[name]...)
	if rm := form["remove_"+name]; len(rm) > 0 && rm[0] != "" {
		values = removeTag(values, rm[0])
	}
	if add := form["add_"+name]; len(add) > 0 {
		values = addTag(values, add[0])
	}
	return joinTags(values)
}
