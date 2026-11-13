package host

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"remotedebug/core/internal/direct"
	"remotedebug/core/internal/events"
)

// TestDirectSmokeServer is the Mac half of a manual end-to-end check with the
// iPhone app's real pinned transport (Packages/PhoneClient DirectSmokeTests).
// It runs only when RD_DIRECT_SMOKE_FILE names a file to write.
//
// It serves the real direct listener on this machine's private address with
// the production address filter, enrolls a device through the tailnet
// handler, writes what the client needs to the file, and waits for
// "<file>.done". Then it checks what reached the HTTP handler.
func TestDirectSmokeServer(t *testing.T) {
	out := os.Getenv("RD_DIRECT_SMOKE_FILE")
	if out == "" {
		t.Skip("RD_DIRECT_SMOKE_FILE is not set")
	}
	var lan string
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if p, err := netip.ParsePrefix(a.String()); err == nil && p.Addr().Is4() && direct.IsLANAddr(p.Addr()) && !p.Addr().IsLinkLocalUnicast() {
			lan = p.Addr().String()
			break
		}
	}
	if lan == "" {
		t.Skip("this machine has no private IPv4 address")
	}
	id, err := direct.Load(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	ln, err := id.Listen(direct.Options{Host: lan}) // production filter: private peers only
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	h, err := New(Options{
		WhoIs: func(ctx context.Context, remoteAddr string) (Peer, error) {
			return Peer{StableID: "n_phone", NodeName: "rd-phone-00000001"}, nil
		},
		Events:     events.New(events.DefaultCapacity),
		PublishDir: dir,
		Info:       func() Info { return Info{HostID: "h_4be0c7a1", HostName: "Mac", FQDN: "rd-mac-1.example.ts.net"} },
		BaseURL:    func() string { return "https://rd-mac-1.example.ts.net" },
		Direct: func() (DirectInfo, bool) {
			return DirectInfo{ID: id.ID(), Port: id.Port(), SPKI: id.SPKI()}, true
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(h.Close)
	h.SetDevices([]DeviceEntry{{ID: "d_1", Name: "시험 iPhone", NodeStableID: "n_phone", NodeName: "rd-phone-00000001"}})

	pub, _ := filepath.EvalSymlinks(dir)
	req := writeResource(t, pub, "smoke.bin", strings.Repeat("0123456789abcdef", 200_000)) // 3.2 MB
	resID, err := h.PublishResource(req)
	if err != nil {
		t.Fatal(err)
	}
	e := enroll(t, h)

	var mu sync.Mutex
	hits := map[string]int{}
	authorized := 0
	inner := h.DirectHandler()
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		hits[r.Method+" "+r.URL.Path]++
		if r.Header.Get("Authorization") == authOf(e) {
			authorized++
		}
		mu.Unlock()
		inner.ServeHTTP(w, r)
	})}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })

	info, _ := json.Marshal(map[string]any{
		"address": lan, "port": e.Port, "spki": e.TLSSPKI, "deviceId": e.DeviceID, "token": e.Token,
		"hostId": "h_4be0c7a1", "resourceId": resID, "resourceName": req.Name, "size": req.Size, "sha256": req.SHA256,
	})
	if err := os.WriteFile(out, info, 0o600); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Minute)
	for {
		if _, err := os.Stat(out + ".done"); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the client did not finish")
		}
		time.Sleep(200 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	t.Logf("handler hits: %v, with the device token: %d", hits, authorized)
	total := 0
	for _, n := range hits {
		total += n
	}
	// The client makes: info, resources, one download with the right pin, and
	// one info attempt with a wrong pin, which must not reach the handler.
	if hits["GET /v1/info"] != 1 || hits["GET /v1/resources"] != 1 || hits["GET /v1/resources/"+resID] < 1 {
		t.Fatalf("unexpected requests: %v", hits)
	}
	if authorized != total {
		t.Fatalf("%d of %d requests carried the token", authorized, total)
	}
}
