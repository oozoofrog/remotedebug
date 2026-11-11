package host

import (
	"strings"
	"testing"
)

func TestBaseURL(t *testing.T) {
	cases := []struct {
		tls  bool
		fqdn string
		port int
		want string
	}{
		{true, "rd-mac-ab12cd34.example.ts.net.", 443, "https://rd-mac-ab12cd34.example.ts.net"},
		{true, "rd-mac-ab12cd34.example.ts.net", 8443, "https://rd-mac-ab12cd34.example.ts.net:8443"},
		{false, "rd-mac-x.rd-test.ts.net", 8080, "http://rd-mac-x.rd-test.ts.net:8080"},
	}
	for _, c := range cases {
		if got := BaseURL(c.tls, c.fqdn, c.port); got != c.want {
			t.Errorf("BaseURL(%v,%q,%d) = %q, want %q", c.tls, c.fqdn, c.port, got, c.want)
		}
	}
}

func TestManifestEscapes(t *testing.T) {
	m := string(Manifest("https://h.ts.net/i/T/app.ipa", "com.example.a&b", "1.0", "<Sample>"))
	for _, want := range []string{
		"<string>https://h.ts.net/i/T/app.ipa</string>",
		"<string>com.example.a&amp;b</string>",
		"<string>&lt;Sample&gt;</string>",
		"<string>software-package</string>",
	} {
		if !strings.Contains(m, want) {
			t.Errorf("manifest missing %q", want)
		}
	}
}

func TestRedactPath(t *testing.T) {
	if got := redactPath("/i/SECRET/app.ipa"); strings.Contains(got, "SECRET") {
		t.Fatalf("token leaked: %q", got)
	}
	if got := redactPath("/v1/info"); got != "/v1/info" {
		t.Fatalf("got %q", got)
	}
}
