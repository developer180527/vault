package jobs

import (
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
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
