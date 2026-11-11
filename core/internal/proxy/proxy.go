// Package proxy is the loopback HTTP CONNECT proxy used by the iOS packet
// tunnel extension (protocol §6). It only relays CONNECT to allowed targets.
package proxy

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"
)

// DialTimeout bounds each tailnet dial.
const DialTimeout = 15 * time.Second

const bufSize = 32 << 10

var bufPool = sync.Pool{New: func() any { b := make([]byte, bufSize); return &b }}

// DialFunc dials a tailnet address.
type DialFunc func(ctx context.Context, network, addr string) (net.Conn, error)

// Proxy is a CONNECT-only proxy with a fixed target allow-list.
type Proxy struct {
	dial    DialFunc
	allowed map[string]bool // normalized host:port
	magic   func() string
	logf    func(format string, args ...any)
	srv     *http.Server
	ln      net.Listener
}

// NormalizeTarget lower-cases the host and strips a trailing dot. It returns
// "" if target is not host:port with a numeric port.
func NormalizeTarget(target string) string {
	host, port, err := net.SplitHostPort(target)
	if err != nil || host == "" || port == "" {
		return ""
	}
	for _, c := range port {
		if c < '0' || c > '9' {
			return ""
		}
	}
	return net.JoinHostPort(strings.TrimSuffix(strings.ToLower(host), "."), port)
}

var (
	tailnetV4 = netip.MustParsePrefix("100.64.0.0/10")
	tailnetV6 = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
)

// IsTailnetIP reports whether ip is a Tailscale address.
func IsTailnetIP(ip netip.Addr) bool {
	ip = ip.Unmap()
	return tailnetV4.Contains(ip) || tailnetV6.Contains(ip)
}

// TailnetTarget reports whether a normalized host:port names a tailnet node:
// a Tailscale IP, a name under ".ts.net", or a name under magicSuffix (the
// node's MagicDNS suffix, "" if unknown).
func TailnetTarget(target, magicSuffix string) bool {
	host, _, err := net.SplitHostPort(target)
	if err != nil {
		return false
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		return IsTailnetIP(ip)
	}
	magicSuffix = strings.Trim(strings.ToLower(magicSuffix), ".")
	return strings.HasSuffix(host, ".ts.net") || magicSuffix != "" && strings.HasSuffix(host, "."+magicSuffix)
}

// New returns a proxy relaying CONNECT for the given targets through dial.
// magicSuffix returns the node's current MagicDNS suffix (may be nil).
func New(dial DialFunc, targets []string, magicSuffix func() string, logf func(string, ...any)) *Proxy {
	if magicSuffix == nil {
		magicSuffix = func() string { return "" }
	}
	p := &Proxy{dial: dial, allowed: map[string]bool{}, magic: magicSuffix, logf: logf}
	for _, t := range targets {
		if n := NormalizeTarget(t); n != "" {
			p.allowed[n] = true
		}
	}
	return p
}

// Serve listens on addr (must be loopback) and serves in the background.
func (p *Proxy) Serve(addr string) (string, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return "", err
	}
	p.ln = ln
	p.srv = &http.Server{Handler: p, ReadHeaderTimeout: 10 * time.Second}
	go p.srv.Serve(ln)
	return ln.Addr().String(), nil
}

// Close stops the listener and open tunnels' accept loop.
func (p *Proxy) Close() error {
	if p.srv == nil {
		return nil
	}
	return p.srv.Close()
}

func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodConnect {
		http.Error(w, "only CONNECT is supported", http.StatusMethodNotAllowed)
		return
	}
	target := NormalizeTarget(r.Host)
	if target == "" || !p.allowed[target] || !TailnetTarget(target, p.magic()) {
		p.logf("proxy: CONNECT to %q not allowed", r.Host)
		http.Error(w, "target not allowed", http.StatusForbidden)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), DialTimeout)
	upstream, err := p.dial(ctx, "tcp", target)
	cancel()
	if err != nil {
		p.logf("proxy: dial %s failed: %v", target, err)
		http.Error(w, "upstream dial failed", http.StatusBadGateway)
		return
	}
	defer upstream.Close()
	// A name that resolved outside the tailnet is never relayed.
	if ap, err := netip.ParseAddrPort(upstream.RemoteAddr().String()); err != nil || !IsTailnetIP(ap.Addr()) {
		p.logf("proxy: %s resolved outside the tailnet", target)
		http.Error(w, "target not allowed", http.StatusForbidden)
		return
	}

	client, brw, err := http.NewResponseController(w).Hijack()
	if err != nil {
		return
	}
	defer client.Close()
	if _, err := io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	// Bytes the client sent after the CONNECT header are already buffered.
	if n := brw.Reader.Buffered(); n > 0 {
		b, _ := brw.Reader.Peek(n)
		if _, err := upstream.Write(b); err != nil {
			return
		}
	}

	done := make(chan struct{}, 2)
	go func() { pipe(upstream, client); done <- struct{}{} }()
	go func() { pipe(client, upstream); done <- struct{}{} }()
	<-done
	<-done
}

// pipe copies src to dst. On EOF it half-closes dst so the other direction
// can finish; on error (or without half-close support) it closes both ends,
// which also ends the opposite pipe.
func pipe(dst, src net.Conn) {
	bp := bufPool.Get().(*[]byte)
	_, err := io.CopyBuffer(dst, src, *bp)
	bufPool.Put(bp)
	if cw, ok := dst.(interface{ CloseWrite() error }); ok && err == nil {
		if cw.CloseWrite() == nil {
			return
		}
	}
	dst.Close()
	src.Close()
}
