// Package direct owns the same-network listener of the host
// (docs/protocol-addenda.md O): its persisted identity (random id, port,
// self-signed TLS key) and a TCP listener that accepts only peers on a
// private or link-local address.
package direct

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

// File names inside the core state dir.
const (
	stateFile = "direct.json"
	keyFile   = "direct-key.pem"
	certFile  = "direct-cert.pem"
)

// ServiceType is the Bonjour service the host app advertises on the port.
const ServiceType = "_remotedebug._tcp"

// state is direct.json.
type state struct {
	ID     string `json:"id"`               // 16 hex chars, generated once per install
	Port   int    `json:"port"`             // chosen once; replaced only if it cannot be bound
	HostID string `json:"hostId,omitempty"` // last known /v1/info hostId
}

// Identity is the persisted identity of the direct listener.
type Identity struct {
	dir  string
	cert tls.Certificate
	spki string

	mu sync.Mutex
	st state
}

// Load reads the identity from dir, creating the id and the TLS key on first
// use. The key and certificate are written once and never rotated: phones pin
// the key.
func Load(dir string) (*Identity, error) {
	id := &Identity{dir: dir}
	if b, err := os.ReadFile(filepath.Join(dir, stateFile)); err == nil {
		json.Unmarshal(b, &id.st) // a damaged file is replaced below
	}
	if !validID(id.st.ID) {
		var raw [8]byte
		if _, err := rand.Read(raw[:]); err != nil {
			return nil, err
		}
		id.st.ID = hex.EncodeToString(raw[:])
		if err := id.save(); err != nil {
			return nil, err
		}
	}
	cert, err := loadOrCreateCert(dir)
	if err != nil {
		return nil, err
	}
	id.cert = cert
	sum := sha256.Sum256(cert.Leaf.RawSubjectPublicKeyInfo)
	id.spki = base64.StdEncoding.EncodeToString(sum[:])
	return id, nil
}

func validID(s string) bool {
	if len(s) != 16 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil
}

// ID is the random instance name advertised over Bonjour.
func (i *Identity) ID() string {
	i.mu.Lock()
	defer i.mu.Unlock()
	return i.st.ID
}

// Port is the persisted port (0 before the first Listen).
func (i *Identity) Port() int {
	i.mu.Lock()
	defer i.mu.Unlock()
	return i.st.Port
}

// SPKI is the base64 SHA-256 of the certificate's SubjectPublicKeyInfo.
func (i *Identity) SPKI() string { return i.spki }

// HostID is the last host id saved with SetHostID.
func (i *Identity) HostID() string {
	i.mu.Lock()
	defer i.mu.Unlock()
	return i.st.HostID
}

// SetHostID remembers the host id so /v1/info can answer on the direct
// listener while the tailnet node is not up yet.
func (i *Identity) SetHostID(hostID string) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if hostID == "" || hostID == i.st.HostID {
		return
	}
	i.st.HostID = hostID
	i.save()
}

// save writes direct.json. The caller holds i.mu (or owns i exclusively).
func (i *Identity) save() error {
	b, err := json.Marshal(i.st)
	if err != nil {
		return err
	}
	return writeFile(filepath.Join(i.dir, stateFile), b)
}

func writeFile(path string, b []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func loadOrCreateCert(dir string) (tls.Certificate, error) {
	keyPath, certPath := filepath.Join(dir, keyFile), filepath.Join(dir, certFile)
	if cert, err := tls.LoadX509KeyPair(certPath, keyPath); err == nil {
		if leaf, err := x509.ParseCertificate(cert.Certificate[0]); err == nil {
			cert.Leaf = leaf
			return cert, nil
		}
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return tls.Certificate{}, err
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "RemoteDebug direct"},
		NotBefore:             now.Add(-24 * time.Hour),
		NotAfter:              now.AddDate(30, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return tls.Certificate{}, err
	}
	if err := writeFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})); err != nil {
		return tls.Certificate{}, err
	}
	if err := writeFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})); err != nil {
		return tls.Certificate{}, err
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}, nil
}

// tailscaleULA is Tailscale's IPv6 range. It lies inside fc00::/7 but is not
// the local network.
var tailscaleULA = netip.MustParsePrefix("fd7a:115c:a1e0::/48")

// IsLANAddr reports whether a is a private (RFC 1918, IPv6 unique local) or
// link-local unicast address. CGNAT (100.64.0.0/10) and Tailscale's IPv6
// range are not: tailnet peers use the tailnet listener.
func IsLANAddr(a netip.Addr) bool {
	a = a.Unmap().WithZone("")
	if !a.IsValid() || tailscaleULA.Contains(a) {
		return false
	}
	return a.IsPrivate() || a.IsLinkLocalUnicast()
}

// AllowLAN is the default peer filter of Listen.
func AllowLAN(remote net.Addr) bool {
	if remote == nil {
		return false
	}
	ap, err := netip.ParseAddrPort(remote.String())
	if err != nil {
		return false
	}
	return IsLANAddr(ap.Addr())
}

// Options change where Listen binds and whom it accepts (tests).
type Options struct {
	Host  string              // "" means all interfaces
	Allow func(net.Addr) bool // nil means AllowLAN
}

// Listen opens the TLS 1.3 listener on the persisted port. The first call
// (or a port that can no longer be bound) picks a free port and persists it.
func (i *Identity) Listen(opt Options) (net.Listener, error) {
	allow := opt.Allow
	if allow == nil {
		allow = AllowLAN
	}
	var (
		ln  net.Listener
		err = errors.New("no port")
	)
	if p := i.Port(); p > 0 {
		ln, err = net.Listen("tcp", net.JoinHostPort(opt.Host, strconv.Itoa(p)))
	}
	if err != nil {
		if ln, err = net.Listen("tcp", net.JoinHostPort(opt.Host, "0")); err != nil {
			return nil, err
		}
		i.mu.Lock()
		i.st.Port = ln.Addr().(*net.TCPAddr).Port
		err = i.save()
		i.mu.Unlock()
		if err != nil {
			ln.Close()
			return nil, err
		}
	}
	return tls.NewListener(&filtered{Listener: ln, allow: allow}, &tls.Config{
		Certificates: []tls.Certificate{i.cert},
		MinVersion:   tls.VersionTLS13,
	}), nil
}

// filtered closes connections from peers the filter rejects before any TLS
// byte is exchanged.
type filtered struct {
	net.Listener
	allow func(net.Addr) bool
}

func (f *filtered) Accept() (net.Conn, error) {
	for {
		c, err := f.Listener.Accept()
		if err != nil {
			return nil, err
		}
		if f.allow(c.RemoteAddr()) {
			return c, nil
		}
		c.Close()
	}
}
