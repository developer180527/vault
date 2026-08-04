package jobs

import (
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
)

// Reading the info hash out of a .torrent file.
//
// A magnet link carries its hash in the URI; a .torrent file does not — the v1
// info hash is DEFINED as the SHA-1 of the bencoded `info` dictionary, exactly
// as it appears in the file. So we locate that dictionary's byte range and hash
// it verbatim; re-encoding it would risk changing key order or integer form and
// produce a different (wrong) hash.
//
// Deriving the hash ourselves keeps adding a file deterministic and
// single-shot. The alternative — add it, then diff qBittorrent's list to work
// out which torrent appeared — races with any other add and needs extra round
// trips.
//
// Limitation, stated plainly: this is the v1 (SHA-1) hash. A v2-only torrent
// has no v1 hash; qBittorrent reports v1 hashes for v1 and hybrid torrents,
// which is everything in practice. A v2-only file is rejected rather than
// silently mis-keyed.

var (
	// ErrNotTorrent — the bytes aren't a bencoded torrent at all.
	ErrNotTorrent = errors.New("not a .torrent file")
	// ErrNoInfoDict — bencode parsed, but there's no top-level "info" dict.
	ErrNoInfoDict = errors.New("torrent has no info dictionary")
)

// TorrentInfoHash returns the lowercased hex v1 info hash of a .torrent file.
func TorrentInfoHash(b []byte) (string, error) {
	if len(b) == 0 || b[0] != 'd' {
		return "", ErrNotTorrent
	}
	i := 1 // just past the opening 'd' of the top-level dict
	for i < len(b) && b[i] != 'e' {
		key, next, err := bencodeString(b, i)
		if err != nil {
			return "", ErrNotTorrent
		}
		start := next
		end, err := bencodeSkip(b, start)
		if err != nil {
			return "", ErrNotTorrent
		}
		if string(key) == "info" {
			if b[start] != 'd' {
				return "", ErrNoInfoDict
			}
			sum := sha1.Sum(b[start:end])
			return hex.EncodeToString(sum[:]), nil
		}
		i = end
	}
	return "", ErrNoInfoDict
}

// bencodeString reads a `<len>:<bytes>` string at i, returning it and the index
// just past it.
func bencodeString(b []byte, i int) ([]byte, int, error) {
	j := i
	for j < len(b) && b[j] >= '0' && b[j] <= '9' {
		j++
	}
	if j == i || j >= len(b) || b[j] != ':' {
		return nil, 0, ErrNotTorrent
	}
	n := 0
	for _, c := range b[i:j] {
		n = n*10 + int(c-'0')
		if n < 0 || n > len(b) { // overflow or absurd length
			return nil, 0, ErrNotTorrent
		}
	}
	start := j + 1
	end := start + n
	if end > len(b) {
		return nil, 0, ErrNotTorrent
	}
	return b[start:end], end, nil
}

// bencodeSkip returns the index just past the complete bencode value at i,
// without decoding it — all we need is to walk to the next key.
func bencodeSkip(b []byte, i int) (int, error) {
	if i >= len(b) {
		return 0, ErrNotTorrent
	}
	switch c := b[i]; {
	case c == 'i': // i<digits>e
		j := i + 1
		for j < len(b) && b[j] != 'e' {
			j++
		}
		if j >= len(b) {
			return 0, ErrNotTorrent
		}
		return j + 1, nil
	case c == 'l', c == 'd': // list / dict: skip members until 'e'
		j := i + 1
		for j < len(b) && b[j] != 'e' {
			var err error
			if c == 'd' {
				// Dict members are key/value pairs; keys are always strings.
				if _, j, err = bencodeString(b, j); err != nil {
					return 0, err
				}
			}
			if j, err = bencodeSkip(b, j); err != nil {
				return 0, err
			}
		}
		if j >= len(b) {
			return 0, ErrNotTorrent
		}
		return j + 1, nil
	case c >= '0' && c <= '9':
		_, end, err := bencodeString(b, i)
		return end, err
	default:
		return 0, fmt.Errorf("%w: unexpected byte %q", ErrNotTorrent, c)
	}
}
