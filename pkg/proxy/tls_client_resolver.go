package proxy

import (
	"context"
	"fmt"
	"net"
	"time"
)

// vkHTTPDialer gives bogdanfinn/tls-client an explicit resolver. iOS Network
// Extensions can intermittently lose usable system DNS after full-tunnel
// routes are installed; relying on the default resolver produced long
// credential-fill stalls like "lookup api.vk.me: i/o timeout".
func vkHTTPDialer() net.Dialer {
	d := protectedDialer(12*time.Second, 30*time.Second)
	d.Resolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			servers := []string{
				"1.1.1.1:53",
				"1.0.0.1:53",
				"8.8.8.8:53",
				"8.8.4.4:53",
				"77.88.8.8:53",
				"77.88.8.1:53",
			}
			var lastErr error
			for _, server := range servers {
				conn, err := protectedDialContext(ctx, network, server, 3*time.Second)
				if err == nil {
					return conn, nil
				}
				lastErr = err
			}
			return nil, fmt.Errorf("all DNS resolvers failed: %w", lastErr)
		},
	}
	return d
}
