package proxy

import (
	"context"
	"fmt"
	"net"
	"syscall"
	"time"
)

var socketProtector func(int) bool

// SetSocketProtector installs a platform callback used to exclude outbound
// sockets from a local VPN tunnel. Android supplies VpnService.protect(fd).
// iOS leaves this unset.
func SetSocketProtector(fn func(int) bool) {
	socketProtector = fn
}

func protectedDialer(timeout, keepAlive time.Duration) net.Dialer {
	return net.Dialer{
		Timeout:   timeout,
		KeepAlive: keepAlive,
		Control: func(_, _ string, c syscall.RawConn) error {
			return protectRawConn(c)
		},
	}
}

func protectedDialContext(ctx context.Context, network, addr string, timeout time.Duration) (net.Conn, error) {
	d := protectedDialer(timeout, 30*time.Second)
	return d.DialContext(ctx, network, addr)
}

func protectedDialUDP(ctx context.Context, network string, laddr, raddr *net.UDPAddr, timeout time.Duration) (*net.UDPConn, error) {
	d := protectedDialer(timeout, 30*time.Second)
	conn, err := d.DialContext(ctx, network, raddr.String())
	if err != nil {
		return nil, err
	}
	udp, ok := conn.(*net.UDPConn)
	if !ok {
		_ = conn.Close()
		return nil, fmt.Errorf("expected *net.UDPConn, got %T", conn)
	}
	return udp, nil
}

func protectedListenUDP(network string, laddr *net.UDPAddr) (*net.UDPConn, error) {
	lc := net.ListenConfig{
		Control: func(_, _ string, c syscall.RawConn) error {
			return protectRawConn(c)
		},
	}
	conn, err := lc.ListenPacket(context.Background(), network, laddr.String())
	if err != nil {
		return nil, err
	}
	udp, ok := conn.(*net.UDPConn)
	if !ok {
		_ = conn.Close()
		return nil, fmt.Errorf("expected *net.UDPConn, got %T", conn)
	}
	return udp, nil
}

func protectRawConn(c syscall.RawConn) error {
	fn := socketProtector
	if fn == nil {
		return nil
	}
	var protectErr error
	if err := c.Control(func(fd uintptr) {
		if !fn(int(fd)) {
			protectErr = fmt.Errorf("socket protector rejected fd %d", fd)
		}
	}); err != nil {
		return err
	}
	return protectErr
}
