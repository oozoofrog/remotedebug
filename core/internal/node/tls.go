package node

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"

	"tailscale.com/tsnet"
)

// This file is the production HTTPS path (protocol §1: tailnet TCP 443 with a
// MagicDNS certificate). The fake tailnet (testcontrol) cannot issue
// certificates, so these two functions are NOT covered by automated tests;
// tests run with listenTLS=false against a loopback control server.

// listenTailnetTLS listens on the tailnet with TLS using the node's
// MagicDNS certificate (requires MagicDNS + HTTPS enabled on the tailnet).
// It does what tsnet's ListenTLS does, but waits for Running with ctx
// instead of context.Background, so it cannot block rd_stop.
func listenTailnetTLS(ctx context.Context, srv *tsnet.Server, port int) (net.Listener, error) {
	st, err := srv.Up(ctx)
	if err != nil {
		return nil, err
	}
	if !st.CurrentTailnet.MagicDNSEnabled {
		return nil, errors.New("MagicDNS가 꺼져 있습니다(관리 콘솔 DNS 페이지에서 켜야 합니다)")
	}
	if len(st.CertDomains) == 0 {
		return nil, errors.New("HTTPS 인증서가 꺼져 있습니다(관리 콘솔에서 HTTPS를 켜야 합니다)")
	}
	lc, err := srv.LocalClient()
	if err != nil {
		return nil, err
	}
	ln, err := srv.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		return nil, err
	}
	return tls.NewListener(ln, &tls.Config{GetCertificate: lc.GetCertificate}), nil
}

// warmTailnetCert obtains (or loads from cache) the certificate for fqdn.
func warmTailnetCert(ctx context.Context, srv *tsnet.Server, fqdn string) error {
	lc, err := srv.LocalClient()
	if err != nil {
		return err
	}
	_, _, err = lc.CertPair(ctx, fqdn)
	return err
}
