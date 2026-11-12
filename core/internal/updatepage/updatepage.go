// Package updatepage serves the RemoteDebug iPhone app's own update page on
// loopback (protocol-addenda I). The Mac's official Tailscale app forwards a
// secret HTTPS path to it with `tailscale serve`, so the iPhone can install a
// new RemoteDebug build over the official Tailscale VPN instead of the app's
// own VPN, which iOS stops while it replaces the app.
package updatepage

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"html/template"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"sync"
	"time"

	"remotedebug/core/internal/host"
)

// Page is the build the update page offers.
type Page struct {
	BundleID    string `json:"bundleId"`
	Title       string `json:"title"`
	Version     string `json:"version"`
	BuildNumber string `json:"buildNumber"`
	MinOS       string `json:"minOS"`
	Size        int64  `json:"size"`
	SHA256      string `json:"sha256"`
	PublishedAt string `json:"publishedAt"`
	IPAPath     string `json:"ipaPath"`
	Icon        []byte `json:"icon,omitempty"`
}

// Config is the rd_update_page_set input. An empty Listen stops the server.
// PublicURL is the https URL (ending in "/") the official Tailscale app serves
// this page at; empty means the route is not set up yet.
type Config struct {
	Listen    string `json:"listen"`
	PublicURL string `json:"publicURL"`
	Page      *Page  `json:"page"`
}

var (
	mu     sync.Mutex
	cfg    Config
	ln     net.Listener
	server *http.Server
)

// Set applies c, starting, moving or stopping the loopback listener as
// needed. It returns the address the server listens on ("" when stopped).
func Set(c Config) (string, error) {
	if c.PublicURL != "" {
		u, err := url.Parse(c.PublicURL)
		if err != nil || u.Scheme != "https" || u.Host == "" || !strings.HasSuffix(u.Path, "/") {
			return "", errors.New("publicURL은 /로 끝나는 https 주소여야 합니다")
		}
	}
	if c.Page != nil && (c.Page.IPAPath == "" || c.Page.BundleID == "") {
		return "", errors.New("page에는 ipaPath와 bundleId가 필요합니다")
	}
	mu.Lock()
	defer mu.Unlock()
	if c.Listen == "" {
		stopLocked()
		cfg = c
		return "", nil
	}
	if ln == nil || (c.Listen != cfg.Listen && c.Listen != ln.Addr().String()) {
		host, _, err := net.SplitHostPort(c.Listen)
		if err != nil || !net.ParseIP(host).IsLoopback() {
			return "", errors.New("listen은 루프백 주소여야 합니다")
		}
		l, err := net.Listen("tcp", c.Listen)
		if err != nil {
			return "", fmt.Errorf("%s에서 기다리지 못했습니다: %w", c.Listen, err)
		}
		stopLocked()
		ln = l
		server = &http.Server{Handler: http.HandlerFunc(handle), ReadHeaderTimeout: 10 * time.Second}
		go server.Serve(l)
	}
	cfg = c
	return ln.Addr().String(), nil
}

func stopLocked() {
	if server != nil {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		server.Shutdown(ctx)
		cancel()
	}
	server, ln = nil, nil
}

// PublicURL is the page address iPhones should open, or "" when the page is
// not reachable or has no build. The host reports it in /v1/info.
func PublicURL() string {
	mu.Lock()
	defer mu.Unlock()
	if ln == nil || cfg.Page == nil {
		return ""
	}
	return cfg.PublicURL
}

func current() Config {
	mu.Lock()
	defer mu.Unlock()
	return cfg
}

// handle serves index, manifest, IPA and icon. Only the last path segment
// matters, so the page works whether or not the proxy strips its mount path.
func handle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	c := current()
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	name := path.Base(r.URL.Path)
	if strings.HasSuffix(r.URL.Path, "/") {
		name = "index.html"
	}
	switch name {
	case "index.html":
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		var buf bytes.Buffer
		pageTemplate.Execute(&buf, view(c))
		w.Write(buf.Bytes())
	case "manifest.plist":
		if c.Page == nil || c.PublicURL == "" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/xml")
		w.Write(host.Manifest(c.PublicURL+"RemoteDebug.ipa", c.Page.BundleID, c.Page.Version, c.Page.Title))
	case "RemoteDebug.ipa":
		if c.Page == nil {
			http.NotFound(w, r)
			return
		}
		f, err := os.Open(c.Page.IPAPath)
		if err != nil {
			http.Error(w, "build is gone", http.StatusGone)
			return
		}
		defer f.Close()
		fi, err := f.Stat()
		if err != nil || fi.Size() != c.Page.Size {
			http.Error(w, "build changed", http.StatusGone)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		http.ServeContent(w, r, "", fi.ModTime(), f)
	case "icon.png":
		if c.Page == nil || len(c.Page.Icon) == 0 {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		w.Write(c.Page.Icon)
	default:
		http.NotFound(w, r)
	}
}

type pageView struct {
	Page    *Page
	Install string
	HasIcon bool
	Ready   bool
}

func view(c Config) pageView {
	v := pageView{Page: c.Page, HasIcon: c.Page != nil && len(c.Page.Icon) > 0}
	if c.Page != nil && c.PublicURL != "" {
		v.Ready = true
		v.Install = "itms-services://?action=download-manifest&url=" + url.QueryEscape(c.PublicURL+"manifest.plist")
	}
	return v
}

var pageTemplate = template.Must(template.New("page").Funcs(template.FuncMap{
	"safeURL": func(s string) template.URL { return template.URL(s) },
}).Parse(`<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RemoteDebug 업데이트</title>
<style>
:root{color-scheme:light dark;--tint:#0a8c94}
body{font:17px -apple-system,system-ui,sans-serif;margin:0;padding:24px 16px;max-width:520px;margin:auto}
.app{display:flex;gap:14px;align-items:center;margin-bottom:20px}
.app img{width:64px;height:64px;border-radius:14px}
h1{font-size:22px;margin:0}
.meta{color:gray;font-size:15px;margin-top:4px}
a.button{display:block;text-align:center;background:var(--tint);color:#fff;text-decoration:none;font-weight:600;padding:14px;border-radius:12px;margin:20px 0}
ol{padding-left:20px}li{margin:8px 0}
.note{color:gray;font-size:14px}
</style></head><body>
{{if .Page}}
<div class="app">{{if .HasIcon}}<img src="icon.png" alt="">{{end}}
<div><h1>{{.Page.Title}}</h1><div class="meta">{{.Page.Version}} ({{.Page.BuildNumber}}) · iOS {{.Page.MinOS}} 이상</div></div></div>
{{if .Ready}}<a class="button" href="{{safeURL .Install}}">설치</a>{{else}}<p>Mac 앱에서 공식 Tailscale 연결을 켜야 설치할 수 있습니다.</p>{{end}}
<ol>
<li>iOS 창에서 <b>설치</b>를 누릅니다. 설치하는 동안 RemoteDebug 앱이 닫힙니다.</li>
<li>홈 화면에서 RemoteDebug를 열고 앱의 VPN을 다시 켭니다. 공식 Tailscale VPN은 꺼집니다.</li>
<li>설정 &gt; "이 앱"에서 버전을 확인합니다.</li>
</ol>
<p class="note">앱이 열리지 않으면 설정 &gt; 일반 &gt; VPN 및 기기 관리에서 개발자를 신뢰하고, 설정 &gt; 개인정보 보호 및 보안 &gt; 개발자 모드를 확인하세요.</p>
<p class="note">SHA-256 {{.Page.SHA256}}</p>
{{else}}
<h1>RemoteDebug 업데이트</h1>
<p>Mac에 게시된 RemoteDebug iPhone 빌드가 없습니다. Mac에서 RemoteDebugPhone 스킴을 빌드해 게시한 뒤 새로고침하세요.</p>
{{end}}
</body></html>
`))
