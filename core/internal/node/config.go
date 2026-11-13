// Package node runs one RemoteDebug core instance: a tsnet node in host mode
// (tailnet REST server) or proxy mode (loopback CONNECT proxy), or a
// Tailscale engine on the Network Extension's utun in tunnel mode
// (docs/tunnel.md).
package node

import (
	"encoding/json"
	"net"
	"net/url"
	"strings"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/proxy"
)

// Config is the rd_start configuration (protocol §9).
type Config struct {
	Mode           string   `json:"mode"`
	StateDir       string   `json:"stateDir"`
	Hostname       string   `json:"hostname"`
	AuthKey        string   `json:"authKey"` // secret: never log
	ControlURL     string   `json:"controlURL"`
	Ephemeral      bool     `json:"ephemeral"`
	ListenTLS      *bool    `json:"listenTLS"` // absent means true
	Port           int      `json:"port"`      // 0 means 443
	PublishDir     string   `json:"publishDir"`
	AllowedTargets []string `json:"allowedTargets"`
	GoMemLimitMiB  int      `json:"goMemLimitMiB"`
	LogPath        string   `json:"logPath"`

	// Tunnel mode only (docs/tunnel.md).
	UtunFd int `json:"utunFd"` // utun control socket; the caller keeps owning it
	MTU    int `json:"mtu"`    // 0 means DefaultMTU

	// Optional extensions (docs/protocol-addenda.md): shown in /v1/info.
	HostDisplayName string `json:"hostDisplayName"`
	AppVersion      string `json:"appVersion"`

	// Host mode: open the same-network listener at start
	// (docs/protocol-addenda.md O). rd_host_set_direct changes it later.
	DirectListen bool `json:"directListen"`
}

// MaxGoMemLimitMiB bounds goMemLimitMiB.
const MaxGoMemLimitMiB = 4096

// Tunnel MTU bounds: 1280 is the IPv6 minimum and Tailscale's default; above
// 1420 the WireGuard packet exceeds a 1500-byte path.
const (
	DefaultMTU = 1280
	MaxMTU     = 1420
)

// TLS reports whether the host listener uses tailnet TLS.
func (c *Config) TLS() bool { return c.ListenTLS == nil || *c.ListenTLS }

// ParseConfig decodes and validates rd_start's JSON.
func ParseConfig(raw string) (*Config, error) {
	var c Config
	if err := json.Unmarshal([]byte(raw), &c); err != nil {
		return nil, apierr.InvalidConfig("설정 JSON을 읽지 못했습니다.")
	}
	if err := c.validate(); err != nil {
		return nil, err
	}
	return &c, nil
}

func (c *Config) validate() error {
	switch c.Mode {
	case "host", "proxy", "tunnel":
	default:
		return apierr.InvalidConfig(`mode는 "host", "proxy", "tunnel" 중 하나여야 합니다.`)
	}
	if c.StateDir == "" {
		return apierr.InvalidConfig("stateDir가 필요합니다.")
	}
	if !validHostname(c.Hostname) {
		return apierr.InvalidConfig("hostname은 영문 소문자·숫자·하이픈 1~63자여야 합니다.")
	}
	if c.ControlURL != "" {
		u, err := url.Parse(c.ControlURL)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return apierr.InvalidConfig("controlURL이 올바른 http(s) 주소가 아닙니다.")
		}
	}
	if c.GoMemLimitMiB < 0 || c.GoMemLimitMiB > MaxGoMemLimitMiB {
		return apierr.InvalidConfig("goMemLimitMiB는 0 이상 4096 이하여야 합니다.")
	}
	if c.Mode == "tunnel" {
		// port, listenTLS, publishDir and allowedTargets are ignored.
		if c.MTU == 0 {
			c.MTU = DefaultMTU
		}
		if c.MTU < DefaultMTU || c.MTU > MaxMTU {
			return apierr.InvalidConfig("mtu는 1280 이상 1420 이하여야 합니다.")
		}
		if c.HostDisplayName == "" {
			c.HostDisplayName = c.Hostname
		}
		return nil
	}
	if c.Port == 0 {
		c.Port = 443
	}
	if c.Port < 1 || c.Port > 65535 {
		return apierr.InvalidConfig("port 범위가 잘못되었습니다.")
	}
	if !c.TLS() && !isLoopbackURL(c.ControlURL) {
		return apierr.InvalidConfig("listenTLS=false는 controlURL이 루프백(가짜 tailnet)일 때만 허용합니다.")
	}
	if c.Mode == "host" && c.PublishDir == "" {
		return apierr.InvalidConfig("host 모드에는 publishDir가 필요합니다.")
	}
	for _, t := range c.AllowedTargets {
		n := proxy.NormalizeTarget(t)
		if n == "" {
			return apierr.InvalidConfig("allowedTargets 항목은 host:port 형식이어야 합니다.")
		}
		if !proxy.TailnetTarget(n, "") {
			return apierr.InvalidConfig("allowedTargets 항목은 tailnet 주소(*.ts.net 이름이나 Tailscale IP)여야 합니다.")
		}
	}
	if c.HostDisplayName == "" {
		c.HostDisplayName = c.Hostname
	}
	return nil
}

func validHostname(s string) bool {
	if len(s) == 0 || len(s) > 63 || s[0] == '-' || s[len(s)-1] == '-' {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
			return false
		}
	}
	return true
}

// isLoopbackURL reports whether u's host is a loopback IP or "localhost".
func isLoopbackURL(u string) bool {
	if u == "" {
		return false
	}
	p, err := url.Parse(u)
	if err != nil {
		return false
	}
	return IsLoopbackHost(p.Hostname())
}

// IsLoopbackHost reports whether host is "localhost" or a loopback IP.
func IsLoopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
