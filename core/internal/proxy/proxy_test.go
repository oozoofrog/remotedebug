package proxy

import "testing"

func TestNormalizeTarget(t *testing.T) {
	cases := map[string]string{
		"RD-Mac.Example.TS.net:443":  "rd-mac.example.ts.net:443",
		"rd-mac.example.ts.net.:443": "rd-mac.example.ts.net:443",
		"rd-mac.example.ts.net":      "",
		"host:https":                 "",
		":443":                       "",
	}
	for in, want := range cases {
		if got := NormalizeTarget(in); got != want {
			t.Errorf("NormalizeTarget(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestTailnetTarget(t *testing.T) {
	cases := []struct {
		target, suffix string
		want           bool
	}{
		{"rd-mac.example.ts.net:443", "", true},
		{"100.64.0.10:443", "", true},
		{"100.127.255.254:443", "", true},
		{"[fd7a:115c:a1e0::1]:443", "", true},
		{"rd-mac.corp.example:443", "corp.example", true},
		{"rd-mac.corp.example:443", "", false},
		{"example.com:443", "corp.example", false},
		{"ts.net:443", "", false},
		{"evil-ts.net:443", "", false},
		{"8.8.8.8:443", "", false},
		{"100.128.0.1:443", "", false},
		{"[fd7a:115c:a1e1::1]:443", "", false},
		{"[::ffff:100.64.0.1]:443", "", true},
	}
	for _, c := range cases {
		if got := TailnetTarget(c.target, c.suffix); got != c.want {
			t.Errorf("TailnetTarget(%q, %q) = %v, want %v", c.target, c.suffix, got, c.want)
		}
	}
}
