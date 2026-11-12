package updatepage

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func get(t *testing.T, url string) (int, string) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func TestUpdatePage(t *testing.T) {
	t.Cleanup(func() { Set(Config{}) })
	ipa := filepath.Join(t.TempDir(), "b.ipa")
	os.WriteFile(ipa, []byte("IPA-BYTES"), 0o600)

	// No build yet: the page explains, the IPA is missing, info reports nothing.
	addr, err := Set(Config{Listen: "127.0.0.1:0", PublicURL: "https://mac.example.ts.net/rd-update-x/"})
	if err != nil || addr == "" {
		t.Fatalf("set: %q %v", addr, err)
	}
	base := "http://" + addr
	if code, body := get(t, base+"/"); code != 200 || !strings.Contains(body, "빌드가 없습니다") {
		t.Fatalf("empty page %d %q", code, body)
	}
	if code, _ := get(t, base+"/RemoteDebug.ipa"); code != 404 {
		t.Fatalf("ipa without page %d", code)
	}
	if PublicURL() != "" {
		t.Fatal("PublicURL without page")
	}

	page := &Page{BundleID: "com.example.phone", Title: "RemoteDebug", Version: "0.2.0", BuildNumber: "7", MinOS: "26.0", Size: 9, IPAPath: ipa}
	addr2, err := Set(Config{Listen: "127.0.0.1:0", PublicURL: "https://mac.example.ts.net/rd-update-x/", Page: page})
	if err != nil || addr2 != addr {
		t.Fatalf("same listener expected: %q %q %v", addr, addr2, err)
	}
	if PublicURL() != "https://mac.example.ts.net/rd-update-x/" {
		t.Fatalf("PublicURL %q", PublicURL())
	}
	// Mount path kept or stripped by the proxy: both work.
	for _, p := range []string{"/", "/rd-update-x/"} {
		code, body := get(t, base+p)
		if code != 200 || !strings.Contains(body, "itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fmac.example.ts.net%2Frd-update-x%2Fmanifest.plist") || !strings.Contains(body, "0.2.0 (7)") {
			t.Fatalf("page %s: %d %q", p, code, body)
		}
	}
	if code, body := get(t, base+"/manifest.plist"); code != 200 || !strings.Contains(body, "<string>https://mac.example.ts.net/rd-update-x/RemoteDebug.ipa</string>") {
		t.Fatalf("manifest %d %q", code, body)
	}
	if code, body := get(t, base+"/rd-update-x/RemoteDebug.ipa"); code != 200 || body != "IPA-BYTES" {
		t.Fatalf("ipa %d %q", code, body)
	}

	// The build file changed under the page: refuse rather than serve other bytes.
	os.WriteFile(ipa, []byte("OTHER"), 0o600)
	if code, _ := get(t, base+"/RemoteDebug.ipa"); code != 410 {
		t.Fatalf("changed ipa %d", code)
	}

	if _, err := Set(Config{Listen: "0.0.0.0:0"}); err == nil {
		t.Fatal("non-loopback listen accepted")
	}
	if _, err := Set(Config{Listen: "127.0.0.1:0", PublicURL: "http://x/"}); err == nil {
		t.Fatal("http publicURL accepted")
	}
	if a, err := Set(Config{}); err != nil || a != "" || PublicURL() != "" {
		t.Fatalf("stop: %q %v", a, err)
	}
}
