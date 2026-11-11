// Command rdtestenv is a helper for scripted end-to-end tests.
//
//	rdtestenv control
//	    Starts a fake tailnet (local DERP + testcontrol), prints
//	    {"controlURL":"http://127.0.0.1:P"} and blocks until killed.
//
//	rdtestenv peer --control URL --state-dir DIR [--hostname H] [--authkey K] ACTION ...
//	    Starts a client tsnet node and performs one action:
//	      pair    --host BASE --code C [--device-name N] [--wait 60s]
//	      builds  --host BASE
//	      session --host BASE --build ID
//	      fetch   --url URL [--out FILE] [--headers]
//	    BASE is a base URL such as http://rd-mac-x.rd-test.ts.net:8443 or a
//	    bare FQDN (meaning https://FQDN). Results are printed as one JSON line:
//	    {"status":HTTP_STATUS,"body":…}; fetch prints size and SHA-256 instead
//	    of the body when the response is not JSON. --headers adds the response
//	    headers as "headers".
//
//	rdtestenv host --control URL --state-dir DIR --publish-dir DIR [--hostname H] [--port 8080]
//	    Starts a host-mode core (plain HTTP, fake tailnet only), prints
//	    {"base":"http://FQDN:PORT","fqdn":FQDN} when it listens and runs until
//	    killed. Nothing is published or paired.
//
//	rdtestenv forward --control URL --state-dir DIR --hostname NAME [--authkey K]
//	        --listen 127.0.0.1:PORT --to HOST:PORT
//	    Joins the tailnet as a client node and forwards every TCP connection
//	    accepted on the loopback address to HOST:PORT over the tailnet (HOST
//	    is a MagicDNS name or a tailnet IP). Prints {"listen":"127.0.0.1:PORT"}
//	    when ready (PORT 0 picks a free port) and runs until killed.
//
// --control is required so the tool never falls back to the real Tailscale
// control plane by accident.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"tailscale.com/logtail"
	"tailscale.com/tsnet"

	"remotedebug/core/internal/api"
	"remotedebug/core/internal/faketailnet"
)

func main() {
	log.SetFlags(0)
	logtail.Disable()
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "control":
		err = runControl()
	case "peer":
		err = runPeer(os.Args[2:])
	case "forward":
		err = runForward(os.Args[2:])
	case "host":
		err = runHost(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		printJSON(map[string]any{"error": err.Error()})
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: rdtestenv control | rdtestenv peer --control URL --state-dir DIR ACTION [flags]"+
		" | rdtestenv host --control URL --state-dir DIR --publish-dir DIR"+
		" | rdtestenv forward --control URL --state-dir DIR --hostname NAME --listen 127.0.0.1:PORT --to HOST:PORT")
	os.Exit(2)
}

func printJSON(v any) {
	b, _ := json.Marshal(v)
	fmt.Println(string(b))
}

func runControl() error {
	env, err := faketailnet.Start(nil)
	if err != nil {
		return err
	}
	defer env.Close()
	printJSON(map[string]string{"controlURL": env.ControlURL})
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	return nil
}

func runPeer(args []string) error {
	fs := flag.NewFlagSet("peer", flag.ExitOnError)
	control := fs.String("control", "", "control server URL (required)")
	stateDir := fs.String("state-dir", "", "tsnet state directory (required)")
	hostname := fs.String("hostname", "rd-testpeer", "tailnet hostname")
	authKey := fs.String("authkey", "", "auth key (not needed for the fake tailnet)")
	verbose := fs.Bool("v", false, "log tsnet output to stderr")
	fs.Parse(args)
	if *control == "" || *stateDir == "" || fs.NArg() < 1 {
		usage()
	}

	srv := &tsnet.Server{
		Dir:        *stateDir,
		Hostname:   *hostname,
		ControlURL: *control,
		AuthKey:    *authKey,
		UserLogf:   func(string, ...any) {},
	}
	if *verbose {
		srv.UserLogf = log.Printf
		srv.Logf = log.Printf
	}
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	if _, err := srv.Up(ctx); err != nil {
		return fmt.Errorf("tsnet up: %w", err)
	}
	c := &client{http: srv.HTTPClient()}

	action, rest := fs.Arg(0), fs.Args()[1:]
	af := flag.NewFlagSet(action, flag.ExitOnError)
	hostFlag := af.String("host", "", "host base URL or FQDN")
	code := af.String("code", "", "pairing code")
	deviceName := af.String("device-name", "rdtestenv", "device name sent when pairing")
	wait := af.Duration("wait", 60*time.Second, "how long to wait for a pairing decision")
	buildID := af.String("build", "", "build id")
	rawURL := af.String("url", "", "URL to fetch")
	outFile := af.String("out", "", "file to write the response body to")
	withHeaders := af.Bool("headers", false, "fetch: include the response headers")
	af.Parse(rest)
	base := baseURL(*hostFlag)

	switch action {
	case "pair":
		body, _ := json.Marshal(map[string]string{"code": *code, "deviceName": *deviceName, "platform": "rdtestenv", "clientVersion": "0"})
		st, resp, err := c.do(ctx, "POST", base+"/v1/pair/request", body)
		if err != nil || st != http.StatusAccepted {
			return report(st, resp, err)
		}
		var pr struct{ RequestID string }
		json.Unmarshal(resp, &pr)
		deadline := time.Now().Add(*wait)
		for {
			st, resp, err = c.do(ctx, "GET", base+"/v1/pair/request/"+pr.RequestID, nil)
			var s struct{ State string }
			json.Unmarshal(resp, &s)
			if err != nil || st != http.StatusOK || s.State != "pending" || time.Now().After(deadline) {
				return report(st, resp, err)
			}
			time.Sleep(500 * time.Millisecond)
		}
	case "builds":
		return report(c.do(ctx, "GET", base+"/v1/builds", nil))
	case "session":
		return report(c.do(ctx, "POST", base+"/v1/builds/"+*buildID+"/sessions", nil))
	case "fetch":
		st, hdr, resp, err := c.doHeaders(ctx, "GET", *rawURL, nil)
		if err != nil {
			return err
		}
		if *outFile != "" {
			if err := os.WriteFile(*outFile, resp, 0o644); err != nil {
				return err
			}
		}
		out := map[string]any{"status": st}
		if json.Valid(resp) {
			out["body"] = json.RawMessage(resp)
		} else {
			sum := sha256.Sum256(resp)
			out["size"], out["sha256"] = len(resp), hex.EncodeToString(sum[:])
		}
		if *withHeaders {
			out["headers"] = hdr
		}
		printJSON(out)
		return nil
	default:
		usage()
	}
	return nil
}

func baseURL(h string) string {
	h = strings.TrimSuffix(h, "/")
	if strings.Contains(h, "://") {
		return h
	}
	return "https://" + h
}

func report(status int, body []byte, err error) error {
	if err != nil {
		return err
	}
	var v any = string(body)
	if json.Valid(body) {
		v = json.RawMessage(body)
	}
	printJSON(map[string]any{"status": status, "body": v})
	return nil
}

type client struct{ http *http.Client }

// do performs one request, retrying dial errors briefly while the netmap
// propagates the host's name.
func (c *client) do(ctx context.Context, method, url string, body []byte) (int, []byte, error) {
	st, _, b, err := c.doHeaders(ctx, method, url, body)
	return st, b, err
}

// doHeaders is do that also returns the response headers.
func (c *client) doHeaders(ctx context.Context, method, url string, body []byte) (int, http.Header, []byte, error) {
	var lastErr error
	for i := 0; i < 20; i++ {
		req, err := http.NewRequestWithContext(ctx, method, url, bytes.NewReader(body))
		if err != nil {
			return 0, nil, nil, err
		}
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		resp, err := c.http.Do(req)
		if err != nil {
			lastErr = err
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				break
			}
			time.Sleep(500 * time.Millisecond)
			continue
		}
		defer resp.Body.Close()
		b, err := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header, b, err
	}
	return 0, nil, nil, lastErr
}

// runHost starts a host-mode core on the fake tailnet for manual probes.
func runHost(args []string) error {
	fs := flag.NewFlagSet("host", flag.ExitOnError)
	control := fs.String("control", "", "control server URL (required)")
	stateDir := fs.String("state-dir", "", "core state directory (required)")
	publishDir := fs.String("publish-dir", "", "publish directory (required)")
	hostname := fs.String("hostname", "rd-mac-test0001", "tailnet hostname")
	port := fs.Int("port", 8080, "tailnet port (plain HTTP)")
	fs.Parse(args)
	if *control == "" || *stateDir == "" || *publishDir == "" {
		usage()
	}
	cfg, _ := json.Marshal(map[string]any{
		"mode": "host", "stateDir": *stateDir, "hostname": *hostname, "controlURL": *control,
		"ephemeral": true, "listenTLS": false, "port": *port, "publishDir": *publishDir,
	})
	var started struct {
		Handle int64
		Error  *struct{ Code, Message string }
	}
	if err := json.Unmarshal([]byte(api.Start(string(cfg))), &started); err != nil || started.Handle == 0 {
		if started.Error != nil {
			return fmt.Errorf("rd_start: %s: %s", started.Error.Code, started.Error.Message)
		}
		return fmt.Errorf("rd_start failed")
	}
	defer api.Stop(started.Handle)
	deadline := time.Now().Add(90 * time.Second)
	for {
		var st struct {
			BackendState string
			Listening    bool
			FQDN         string
		}
		json.Unmarshal([]byte(api.Status(started.Handle)), &st)
		if st.BackendState == "Running" && st.Listening && st.FQDN != "" {
			fqdn := strings.TrimSuffix(st.FQDN, ".")
			printJSON(map[string]any{"base": fmt.Sprintf("http://%s:%d", fqdn, *port), "fqdn": fqdn})
			break
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("host did not become ready: %s", api.Status(started.Handle))
		}
		time.Sleep(200 * time.Millisecond)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	return nil
}

func runForward(args []string) error {
	fs := flag.NewFlagSet("forward", flag.ExitOnError)
	control := fs.String("control", "", "control server URL (required)")
	stateDir := fs.String("state-dir", "", "tsnet state directory (required)")
	hostname := fs.String("hostname", "", "tailnet hostname (required)")
	authKey := fs.String("authkey", "", "auth key (not needed for the fake tailnet)")
	listen := fs.String("listen", "", "loopback address to accept on, e.g. 127.0.0.1:8080 (required)")
	to := fs.String("to", "", "tailnet HOST:PORT to forward to (required)")
	verbose := fs.Bool("v", false, "log tsnet output to stderr")
	fs.Parse(args)
	if *control == "" || *stateDir == "" || *hostname == "" || *listen == "" || *to == "" || fs.NArg() != 0 {
		usage()
	}
	if h, _, err := net.SplitHostPort(*listen); err != nil || !isLoopback(h) {
		return fmt.Errorf("--listen must be a loopback host:port, got %q", *listen)
	}
	if _, _, err := net.SplitHostPort(*to); err != nil {
		return fmt.Errorf("--to must be HOST:PORT: %v", err)
	}

	srv := &tsnet.Server{
		Dir:        *stateDir,
		Hostname:   *hostname,
		ControlURL: *control,
		AuthKey:    *authKey,
		UserLogf:   func(string, ...any) {},
	}
	if *verbose {
		srv.UserLogf = log.Printf
		srv.Logf = log.Printf
	}
	defer srv.Close()
	upCtx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	if _, err := srv.Up(upCtx); err != nil {
		return fmt.Errorf("tsnet up: %w", err)
	}

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	printJSON(map[string]string{"listen": ln.Addr().String()})

	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go forwardConn(ctx, srv, c, *to)
	}
}

func isLoopback(h string) bool {
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// forwardConn copies c to and from target over the tailnet. The dial is
// retried briefly while the netmap brings in the target's name.
func forwardConn(ctx context.Context, srv *tsnet.Server, c net.Conn, target string) {
	defer c.Close()
	var up net.Conn
	var err error
	for i := 0; i < 20; i++ {
		dctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		up, err = srv.Dial(dctx, "tcp", target)
		cancel()
		if err == nil || ctx.Err() != nil {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if err != nil {
		log.Printf("forward: dial %s: %v", target, err)
		return
	}
	defer up.Close()
	done := make(chan struct{}, 2)
	pipe := func(dst, src net.Conn) {
		io.Copy(dst, src)
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		} else {
			dst.Close()
		}
		done <- struct{}{}
	}
	go pipe(up, c)
	go pipe(c, up)
	<-done
	<-done
}
