package music

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

// box builds a minimal top-level MP4 box: 4-byte big-endian size + 4-byte type
// + zero padding to fill [size] bytes.
func box(typ string, size int) []byte {
	b := make([]byte, size)
	binary.BigEndian.PutUint32(b[:4], uint32(size))
	copy(b[4:8], typ)
	return b
}

// box64 builds a box using the 64-bit extended size form (size field = 1).
func box64(typ string, size int) []byte {
	b := make([]byte, size)
	binary.BigEndian.PutUint32(b[:4], 1)
	copy(b[4:8], typ)
	binary.BigEndian.PutUint64(b[8:16], uint64(size))
	return b
}

func writeTemp(t *testing.T, parts ...[]byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "clip.m4a")
	var all []byte
	for _, part := range parts {
		all = append(all, part...)
	}
	if err := os.WriteFile(p, all, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestNeedsFaststart(t *testing.T) {
	cases := []struct {
		name  string
		parts [][]byte
		want  bool
	}{
		{
			name:  "moov before mdat is already fast",
			parts: [][]byte{box("ftyp", 16), box("moov", 32), box("mdat", 64)},
			want:  false,
		},
		{
			name:  "mdat before moov needs faststart",
			parts: [][]byte{box("ftyp", 16), box("mdat", 64), box("moov", 32)},
			want:  true,
		},
		{
			name:  "64-bit mdat before moov needs faststart",
			parts: [][]byte{box("ftyp", 16), box64("mdat", 64), box("moov", 32)},
			want:  true,
		},
		{
			name:  "no moov/mdat is left alone",
			parts: [][]byte{box("ftyp", 16), box("free", 16)},
			want:  false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := needsFaststart(writeTemp(t, c.parts...))
			if err != nil {
				t.Fatalf("needsFaststart: %v", err)
			}
			if got != c.want {
				t.Fatalf("needsFaststart = %v, want %v", got, c.want)
			}
		})
	}
}
