package ids

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestPairCode(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		c := NewPairCode()
		if len(c) != PairCodeLen {
			t.Fatalf("len(%q) = %d", c, len(c))
		}
		for _, r := range c {
			if !strings.ContainsRune(crockford, r) {
				t.Fatalf("code %q has non-Crockford char %q", c, r)
			}
		}
		seen[c] = true
	}
	if len(seen) < 990 {
		t.Fatalf("too many duplicate codes: %d unique of 1000", len(seen))
	}
}

func TestNormalizeAndCompare(t *testing.T) {
	const code = "K7M29QXD"
	for _, in := range []string{"K7M29QXD", "K7M2-9QXD", "k7m2-9qxd", " k7m2 9qxd "} {
		if !PairCodeEqual(code, in) {
			t.Errorf("PairCodeEqual(%q) = false", in)
		}
	}
	for _, in := range []string{"", "K7M29QX", "K7M29QXDD", "K7M29QXE", "K7M2_9QXD", "K7M29QXU"} {
		if PairCodeEqual(code, in) {
			t.Errorf("PairCodeEqual(%q) = true", in)
		}
	}
	if got := NormalizePairCode("ol1i-0000"); got != "01110000" {
		t.Errorf("Crockford aliases: got %q", got)
	}
	if got := DisplayPairCode(code); got != "K7M2-9QXD" {
		t.Errorf("DisplayPairCode = %q", got)
	}
}

func TestToken(t *testing.T) {
	a, b := NewToken(), NewToken()
	if len(a) != 43 || a == b {
		t.Fatalf("tokens %q %q", a, b)
	}
	raw, err := base64.RawURLEncoding.DecodeString(a)
	if err != nil || len(raw) != 32 {
		t.Fatalf("decode: %v len %d", err, len(raw))
	}
	if strings.ContainsAny(a, "+/=") {
		t.Fatalf("token %q is not unpadded base64url", a)
	}
}

func TestIDs(t *testing.T) {
	if id := NewID("s_"); len(id) != 10 || !strings.HasPrefix(id, "s_") {
		t.Fatalf("NewID = %q", id)
	}
	// Vector: printf 'com.example.app\n%s' <64 zeros> | shasum -a 256 | cut -c1-8
	if id := BuildID("com.example.app", strings.Repeat("0", 64)); id != "b_484290ac" {
		t.Fatalf("BuildID = %q", id)
	}
	if BuildID("a", "x") == BuildID("b", "x") {
		t.Fatal("BuildID ignores bundle id")
	}
}
