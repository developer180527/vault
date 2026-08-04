package jobs

import (
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// buildTorrent assembles a minimal but REAL bencoded torrent around the given
// info dictionary, with keys before and after it so the scanner has to walk
// past other values to find `info`.
func buildTorrent(info string) []byte {
	return []byte("d" +
		"8:announce" + bstr("http://tracker.test/announce") +
		"13:creation datei1700000000e" +
		"4:info" + info +
		"7:comment" + bstr("after the info dict") +
		"e")
}

func bstr(s string) string {
	return itoa(len(s)) + ":" + s
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var d []byte
	for n > 0 {
		d = append([]byte{byte('0' + n%10)}, d...)
		n /= 10
	}
	return string(d)
}

func TestTorrentInfoHashIsSHA1OfInfoDict(t *testing.T) {
	// A single-file info dict.
	info := "d6:lengthi1024e4:name8:file.bin12:piece lengthi16384e6:pieces20:" +
		strings.Repeat("\x01", 20) + "e"
	got, err := TorrentInfoHash(buildTorrent(info))
	if err != nil {
		t.Fatalf("TorrentInfoHash: %v", err)
	}
	// The hash is DEFINED as SHA-1 over the info dict's exact bytes.
	sum := sha1.Sum([]byte(info))
	want := hex.EncodeToString(sum[:])
	if got != want {
		t.Fatalf("hash = %s, want %s", got, want)
	}
	if len(got) != 40 {
		t.Fatalf("hash %q is not 40 hex chars", got)
	}
}

// The scanner must walk past nested lists/dicts (multi-file torrents, tracker
// tiers) without losing its place and hashing the wrong range.
func TestTorrentInfoHashWithNestedStructures(t *testing.T) {
	info := "d5:filesld6:lengthi10e4:pathl3:sub5:a.txteed6:lengthi20e4:pathl5:b.txteee" +
		"4:name3:dir12:piece lengthi16384e6:pieces20:" +
		strings.Repeat("\x02", 20) + "e"
	// announce-list is a list OF lists of strings — the nesting the scanner
	// has to walk past to reach `info`.
	tiers := "l" +
		"l" + bstr("http://a.test/announce") + "e" +
		"l" + bstr("http://b.test/announce") + "e" +
		"e"
	raw := []byte("d" +
		"13:announce-list" + tiers +
		"4:info" + info +
		"e")
	got, err := TorrentInfoHash(raw)
	if err != nil {
		t.Fatalf("TorrentInfoHash: %v", err)
	}
	sum := sha1.Sum([]byte(info))
	if want := hex.EncodeToString(sum[:]); got != want {
		t.Fatalf("hash = %s, want %s", got, want)
	}
}

func TestTorrentInfoHashRejectsGarbage(t *testing.T) {
	cases := map[string][]byte{
		"empty":        nil,
		"not bencode":  []byte("this is a text file"),
		"truncated":    []byte("d8:announce20:http://tracker.test"),
		"bad length":   []byte("d4:info999999999999:xe"),
		"no info dict": buildTorrent(""),
	}
	for name, in := range cases {
		if _, err := TorrentInfoHash(in); err == nil {
			t.Fatalf("%s: expected an error, got none", name)
		}
	}
}

// An `info` key whose value isn't a dictionary is malformed — it must be
// refused, not hashed into a plausible-looking but meaningless id.
func TestTorrentInfoHashRejectsNonDictInfo(t *testing.T) {
	raw := []byte("d4:info5:helloe")
	if _, err := TorrentInfoHash(raw); !errors.Is(err, ErrNoInfoDict) {
		t.Fatalf("err = %v, want ErrNoInfoDict", err)
	}
}

// A rejected WebUI login must be reported as ErrQbitAuth (a specific
// configuration fault) rather than a generic failure, and must then BACK OFF:
// qBittorrent bans an IP after a handful of failed logins, and the torrent
// view polls every couple of seconds.
func TestQbitLoginFailureIsTypedAndThrottled(t *testing.T) {
	var attempts int32
	srv := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			atomic.AddInt32(&attempts, 1)
			// No SID cookie = rejection, which is what qBittorrent does for a
			// wrong password.
			_, _ = w.Write([]byte("Fails."))
		}))
	defer srv.Close()

	c := NewQbitClient(srv.URL, "admin", "wrong")
	for range 5 {
		err := c.login(t.Context())
		if !errors.Is(err, ErrQbitAuth) {
			t.Fatalf("err = %v, want ErrQbitAuth", err)
		}
	}
	if n := atomic.LoadInt32(&attempts); n != 1 {
		t.Fatalf("hit qBittorrent %d times for 5 logins — a wrong password "+
			"would get vaultd IP-banned; want 1", n)
	}
}

// A good login must clear the backoff, so fixing the password works
// immediately rather than after the retry delay.
func TestQbitLoginSuccessClearsBackoff(t *testing.T) {
	var ok atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			if ok.Load() {
				http.SetCookie(w, &http.Cookie{Name: "SID", Value: "sid"})
			}
			_, _ = w.Write([]byte("."))
		}))
	defer srv.Close()

	c := NewQbitClient(srv.URL, "admin", "pw")
	if err := c.login(t.Context()); !errors.Is(err, ErrQbitAuth) {
		t.Fatalf("first login err = %v, want ErrQbitAuth", err)
	}
	// Simulate the operator fixing the password AND the delay elapsing.
	ok.Store(true)
	c.mu.Lock()
	c.authFailedAt = time.Time{}
	c.mu.Unlock()
	if err := c.login(t.Context()); err != nil {
		t.Fatalf("login after fix = %v, want nil", err)
	}
	// And a later failure is throttled again from scratch.
	c.mu.Lock()
	cleared := c.authFailedAt.IsZero()
	c.mu.Unlock()
	if !cleared {
		t.Fatal("a successful login must clear the failure timestamp")
	}
}

// qBittorrent's session cookie is named "SID" on older builds and
// "QBT_SID_<port>" on 5.x. Matching only "SID" made a SUCCESSFUL login look
// like a rejected one — the feature could not work at all against a modern
// qBittorrent, whatever the password was.
func TestQbitAcceptsEitherSessionCookieName(t *testing.T) {
	for _, name := range []string{"SID", "QBT_SID_8090", "QBT_SID_8080"} {
		var sentCookie string
		srv := httptest.NewServer(http.HandlerFunc(
			func(w http.ResponseWriter, r *http.Request) {
				if strings.HasSuffix(r.URL.Path, "/auth/login") {
					http.SetCookie(w, &http.Cookie{Name: name, Value: "tok"})
					w.WriteHeader(http.StatusNoContent) // 5.x answers 204
					return
				}
				// A later call must present the cookie back, under its own name.
				if c, err := r.Cookie(name); err == nil {
					sentCookie = c.Value
				}
				_, _ = w.Write([]byte("[]"))
			}))

		c := NewQbitClient(srv.URL, "admin", "pw")
		if err := c.login(t.Context()); err != nil {
			t.Fatalf("cookie %q: login = %v, want success", name, err)
		}
		if _, err := c.List(t.Context(), "cat"); err != nil {
			t.Fatalf("cookie %q: list = %v", name, err)
		}
		if sentCookie != "tok" {
			t.Fatalf("cookie %q was not sent back on the next request", name)
		}
		srv.Close()
	}
}
