package e2e

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"remotedebug/core/internal/api"
)

// buildRdtestenv builds cmd/rdtestenv (no cgo) into a test directory.
func buildRdtestenv(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "rdtestenv")
	cmd := exec.Command(filepath.Join(runtime.GOROOT(), "bin", "go"), "build", "-o", bin, "remotedebug/core/cmd/rdtestenv")
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build rdtestenv: %v\n%s", err, out)
	}
	return bin
}

// startForward runs `rdtestenv forward` to target and returns its loopback
// listen address once it prints it.
func startForward(t *testing.T, bin, hostname, target string) string {
	t.Helper()
	cmd := exec.Command(bin, "forward", "--control", env.ControlURL, "--state-dir", filepath.Join(t.TempDir(), "state"),
		"--hostname", hostname, "--listen", "127.0.0.1:0", "--to", target)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cmd.Process.Signal(os.Interrupt)
		done := make(chan struct{})
		go func() { cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			cmd.Process.Kill()
			<-done
		}
	})
	lines := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(stdout)
		if sc.Scan() {
			lines <- sc.Text()
		}
		close(lines)
	}()
	select {
	case line, ok := <-lines:
		var ready struct {
			Listen string `json:"listen"`
		}
		if !ok || json.Unmarshal([]byte(line), &ready) != nil || ready.Listen == "" {
			t.Fatalf("forward %s: first line %q", hostname, line)
		}
		return ready.Listen
	case <-time.After(120 * time.Second):
		t.Fatalf("forward %s: not ready", hostname)
	}
	return ""
}

// TestE2EForward: a plain HTTP client reaches the host through
// `rdtestenv forward` (the coordinator's Swift E2E path). The host sees the
// forwarder's tailnet node: once paired it gets 200, an unpaired forwarder
// gets 403 not_paired.
func TestE2EForward(t *testing.T) {
	h := startHost(t)
	bin := buildRdtestenv(t)
	target := fmt.Sprintf("%s:%d", h.fqdn, h.port) // MagicDNS name over the tailnet
	paired := startForward(t, bin, "rd-fwd-paired", target)
	unpaired := startForward(t, bin, "rd-fwd-unpaired", target)
	c := &http.Client{Timeout: 30 * time.Second}

	var opened struct{ Code string }
	mustDecode(t, api.HostPairingOpen(h.handle, 0), &opened)
	r := do(t, c, "POST", "http://"+paired+"/v1/pair/request", map[string]string{"code": opened.Code, "deviceName": "fwd", "platform": "rdtestenv", "clientVersion": "0"}, nil)
	expectStatus(t, r, http.StatusAccepted, "")
	reqID, _ := r.json(t)["requestId"].(string)
	if out := api.HostPairingDecide(h.handle, reqID, true); apiError(out) != "" {
		t.Fatalf("decide: %s", out)
	}

	r = do(t, c, "GET", "http://"+paired+"/v1/info", nil, nil)
	expectStatus(t, r, http.StatusOK, "")
	if info := r.json(t); info["fqdn"] != h.fqdn {
		t.Fatalf("info: %s", r.body)
	}
	expectStatus(t, do(t, c, "GET", "http://"+unpaired+"/v1/info", nil, nil), http.StatusForbidden, "not_paired")
}
