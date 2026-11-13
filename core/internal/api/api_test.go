package api

import (
	"crypto/tls"
	"encoding/json"
	"net"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"remotedebug/core/internal/direct"
	"remotedebug/core/internal/node"
)

// errorCode checks the protocol error shape and returns the code.
func errorCode(t *testing.T, out string) string {
	t.Helper()
	var v struct {
		Error *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(out), &v); err != nil {
		t.Fatalf("not JSON: %q", out)
	}
	if v.Error == nil || v.Error.Code == "" || v.Error.Message == "" {
		t.Fatalf("not an error object: %s", out)
	}
	var raw map[string]map[string]any
	json.Unmarshal([]byte(out), &raw)
	if len(raw) != 1 || len(raw["error"]) != 2 {
		t.Fatalf("unexpected keys: %s", out)
	}
	return v.Error.Code
}

func TestUnknownHandle(t *testing.T) {
	const h = 987654
	for name, out := range map[string]string{
		"status":    Status(h),
		"stop":      Stop(h),
		"publish":   HostPublish(h, "{}"),
		"unpublish": HostUnpublish(h, "b_x"),
		"devices":   HostSetDevices(h, `{"devices":[]}`),
		"open":      HostPairingOpen(h, 0),
		"decide":    HostPairingDecide(h, "pr_x", true),
		"proxy":     ProxyStart(h, "127.0.0.1:0"),
		"event":     NextEvent(h, 0),
	} {
		if code := errorCode(t, out); code != "unknown_handle" {
			t.Errorf("%s: code %q", name, code)
		}
	}
}

// deadControl is a loopback control URL where nothing listens: a node that
// starts by mistake never reaches the real Tailscale control plane.
const deadControl = "http://127.0.0.1:1"

func TestInvalidConfig(t *testing.T) {
	dir := t.TempDir()
	cfg := func(fields string) string {
		return `{"controlURL":"` + deadControl + `","stateDir":"` + dir + `",` + fields + `}`
	}
	cases := map[string]string{
		"not json":        `{`,
		"bad mode":        cfg(`"mode":"x","hostname":"rd-mac-1"`),
		"no state dir":    `{"mode":"proxy","hostname":"rd-mac-1","controlURL":"` + deadControl + `"}`,
		"bad hostname":    cfg(`"mode":"proxy","hostname":"Bad Name"`),
		"host no publish": cfg(`"mode":"host","hostname":"rd-mac-1"`),
		"bad target":      cfg(`"mode":"proxy","hostname":"rd-p-1","allowedTargets":["nohost"]`),
		"public target":   cfg(`"mode":"proxy","hostname":"rd-p-1","allowedTargets":["example.com:443"]`),
		"bad port":        cfg(`"mode":"proxy","hostname":"rd-p-1","port":70000`),
		"mem limit":       cfg(`"mode":"proxy","hostname":"rd-p-1","goMemLimitMiB":17592186044416`),
	}
	for name, c := range cases {
		out := Start(c)
		if code := errorCode(t, out); code != "invalid_config" {
			t.Errorf("%s: code %q", name, code)
		}
		var started struct{ Handle int64 }
		if json.Unmarshal([]byte(out), &started); started.Handle != 0 {
			Stop(started.Handle)
		}
	}
	// Cases about non-loopback control URLs are checked without starting
	// anything, so a regression cannot reach a real control server.
	for name, c := range map[string]string{
		"plain http, real": `{"mode":"proxy","stateDir":"` + dir + `","hostname":"rd-p-1","listenTLS":false,"controlURL":"https://controlplane.example.com"}`,
		"plain http, none": `{"mode":"proxy","stateDir":"` + dir + `","hostname":"rd-p-1","listenTLS":false}`,
	} {
		_, err := node.ParseConfig(c)
		if err == nil {
			t.Errorf("%s: accepted", name)
		} else if code := errorCode(t, errJSON(err)); code != "invalid_config" {
			t.Errorf("%s: code %q", name, code)
		}
	}
}

// startDead starts a node against the dead loopback control server.
func startDead(t *testing.T, mode, stateDir string) int64 {
	t.Helper()
	pub := t.TempDir()
	out := Start(`{"mode":"` + mode + `","stateDir":"` + stateDir + `","hostname":"rd-mac-dead","controlURL":"` + deadControl + `","publishDir":"` + pub + `"}`)
	var started struct{ Handle int64 }
	json.Unmarshal([]byte(out), &started)
	if started.Handle == 0 {
		t.Fatalf("start: %s", out)
	}
	t.Cleanup(func() { Stop(started.Handle) })
	return started.Handle
}

func TestStateDirInUse(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	h := startDead(t, "proxy", dir)
	// Another spelling of the same directory is still the same directory.
	out := Start(`{"mode":"proxy","stateDir":"` + dir + `/../state/","hostname":"rd-mac-two","controlURL":"` + deadControl + `"}`)
	if errorCode(t, out) != "invalid_config" || !strings.Contains(out, `"message":"state_dir_in_use"`) {
		t.Fatalf("second start: %s", out)
	}
	if out := Stop(h); out != `{"ok":true}` {
		t.Fatalf("stop: %s", out)
	}
	startDead(t, "proxy", dir) // released by rd_stop
}

func TestSetDevicesRequiresDevices(t *testing.T) {
	h := startDead(t, "host", filepath.Join(t.TempDir(), "state"))
	ok := `{"devices":[{"id":"d_1","name":"p","nodeStableId":"nSTABLE1","nodeName":"rd-phone-1"}]}`
	if out := HostSetDevices(h, ok); out != `{"ok":true}` {
		t.Fatalf("set: %s", out)
	}
	for _, bad := range []string{`{}`, `null`, `{"devices":null}`, `{"deviceList":[]}`, `{"devices":{}}`, `[]`} {
		if code := errorCode(t, HostSetDevices(h, bad)); code != "bad_request" {
			t.Errorf("%s: code %q", bad, code)
		}
	}
	var st struct{ PairedDevices int }
	json.Unmarshal([]byte(Status(h)), &st)
	if st.PairedDevices != 1 {
		t.Fatalf("allow-list changed: %d devices", st.PairedDevices)
	}
	if out := HostSetDevices(h, `{"devices":[]}`); out != `{"ok":true}` {
		t.Fatalf("explicit empty list: %s", out)
	}
	json.Unmarshal([]byte(Status(h)), &st)
	if st.PairedDevices != 0 {
		t.Fatalf("after clearing: %d devices", st.PairedDevices)
	}
}

// The same-network listener does not wait for the tailnet: it is up while the
// control server is unreachable, keeps its port and id, and can be switched
// off and on.
func TestDirectListenerRunsWithoutTheTailnet(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	start := func() int64 {
		pub := t.TempDir()
		out := StartWithOptions(`{"mode":"host","stateDir":"`+stateDir+`","hostname":"rd-mac-dead","controlURL":"`+deadControl+`","publishDir":"`+pub+`","directListen":true}`,
			node.Options{Direct: direct.Options{Host: "127.0.0.1", Allow: func(net.Addr) bool { return true }}})
		var started struct{ Handle int64 }
		json.Unmarshal([]byte(out), &started)
		if started.Handle == 0 {
			t.Fatalf("start: %s", out)
		}
		return started.Handle
	}
	type directStatus struct {
		Listening bool
		Port      int
		ID        string
	}
	status := func(h int64) directStatus {
		var st struct{ Direct *directStatus }
		json.Unmarshal([]byte(Status(h)), &st)
		if st.Direct == nil {
			t.Fatalf("no direct status: %s", Status(h))
		}
		return *st.Direct
	}
	h := start()
	first := status(h)
	if !first.Listening || first.Port == 0 || len(first.ID) != 16 {
		t.Fatalf("status %+v", first)
	}
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
	url := "https://127.0.0.1:" + strconv.Itoa(first.Port) + "/v1/info"
	resp, err := client.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden || resp.Header.Get("X-RD-Protocol") != "1" {
		t.Fatalf("stranger: %d", resp.StatusCode)
	}

	if out := HostSetDirect(h, false); !strings.Contains(out, `"listening":false`) {
		t.Fatalf("off: %s", out)
	}
	client.CloseIdleConnections()
	if _, err := client.Get(url); err == nil {
		t.Fatal("listener still answers after it was turned off")
	}
	if out := HostSetDirect(h, true); !strings.Contains(out, `"listening":true`) {
		t.Fatalf("on: %s", out)
	}
	if got := status(h); got.Port != first.Port || got.ID != first.ID {
		t.Fatalf("changed after off/on: %+v", got)
	}
	Stop(h)

	h = start()
	defer Stop(h)
	if got := status(h); got.Port != first.Port || got.ID != first.ID || !got.Listening {
		t.Fatalf("changed after restart: %+v, was %+v", got, first)
	}
}

func TestSetDirectNeedsHostMode(t *testing.T) {
	h := startDead(t, "proxy", filepath.Join(t.TempDir(), "state"))
	if code := errorCode(t, HostSetDirect(h, true)); code != "invalid_config" {
		t.Fatalf("code %q", code)
	}
	// Without directListen a host has no direct status until it is turned on.
	host := startDead(t, "host", filepath.Join(t.TempDir(), "state2"))
	if strings.Contains(Status(host), `"direct"`) {
		t.Fatalf("direct status without directListen: %s", Status(host))
	}
}
