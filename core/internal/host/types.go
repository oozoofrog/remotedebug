package host

import (
	"strconv"
	"strings"
	"time"
)

// Signing is BuildDescriptor.signing (protocol §4.1).
type Signing struct {
	TeamID                 string `json:"teamId"`
	ProfileName            string `json:"profileName"`
	ProfileExpires         string `json:"profileExpires"`
	ProvisionedDeviceCount int    `json:"provisionedDeviceCount"`
	GetTaskAllow           bool   `json:"getTaskAllow"`
}

// IPAInfo is BuildDescriptor.ipa.
type IPAInfo struct {
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

// BuildDescriptor is the build metadata sent to clients (protocol §4.1).
type BuildDescriptor struct {
	ID                    string  `json:"id"`
	BundleID              string  `json:"bundleId"`
	DisplayName           string  `json:"displayName"`
	Version               string  `json:"version"`
	BuildNumber           string  `json:"buildNumber"`
	MinOS                 string  `json:"minOS"`
	Debug                 bool    `json:"debug"`
	Configuration         string  `json:"configuration"`
	ConfigurationEvidence string  `json:"configurationEvidence"`
	Signing               Signing `json:"signing"`
	IPA                   IPAInfo `json:"ipa"`
	PublishedAt           string  `json:"publishedAt"`
	// Icon is an optional app icon PNG (protocol-addenda F). JSON carries it as base64.
	Icon []byte `json:"icon,omitempty"`
}

// MaxIconBytes bounds BuildDescriptor.Icon.
const MaxIconBytes = 64 << 10

var pngSignature = []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}

// PublishRequest is the rd_host_publish input: a BuildDescriptor plus ipaPath.
type PublishRequest struct {
	BuildDescriptor
	IPAPath string `json:"ipaPath"`
}

// DeviceEntry is one allow-list entry (protocol §5).
type DeviceEntry struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	NodeStableID string `json:"nodeStableId"`
	NodeName     string `json:"nodeName"`
	LoginName    string `json:"loginName"`
	PairedAt     string `json:"pairedAt"`
}

// Peer is the tailnet identity of a request, as reported by WhoIs.
type Peer struct {
	StableID  string
	NodeName  string
	LoginName string
}

// Info is the host identity returned by /v1/info.
type Info struct {
	HostID     string
	HostName   string
	FQDN       string
	AppVersion string
}

// Limits holds the protocol timings and counters; zero fields take defaults.
type Limits struct {
	PairRequestTTL     time.Duration // 120 s
	PairMaxFailures    int           // 5
	SessionTTL         time.Duration // 180 s
	SessionMaxTTL      time.Duration // 600 s, counted from creation
	ManifestMaxFetches int           // 5
}

func (l Limits) withDefaults() Limits {
	if l.PairRequestTTL == 0 {
		l.PairRequestTTL = 120 * time.Second
	}
	if l.PairMaxFailures == 0 {
		l.PairMaxFailures = 5
	}
	if l.SessionTTL == 0 {
		l.SessionTTL = 180 * time.Second
	}
	if l.SessionMaxTTL == 0 {
		l.SessionMaxTTL = 600 * time.Second
	}
	if l.ManifestMaxFetches == 0 {
		l.ManifestMaxFetches = 5
	}
	return l
}

// Timestamp formats t as UTC ISO-8601 with a Z suffix.
func Timestamp(t time.Time) string { return t.UTC().Format(time.RFC3339) }

// BaseURL returns the origin clients use to reach the host. With TLS it is
// https://<fqdn> (port omitted when 443); without TLS (fake tailnet tests only)
// it is http://<fqdn>:<port>.
func BaseURL(tls bool, fqdn string, port int) string {
	fqdn = strings.TrimSuffix(fqdn, ".")
	if tls {
		if port == 443 || port == 0 {
			return "https://" + fqdn
		}
		return "https://" + fqdn + ":" + strconv.Itoa(port)
	}
	return "http://" + fqdn + ":" + strconv.Itoa(port)
}
