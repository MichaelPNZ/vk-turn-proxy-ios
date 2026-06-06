//go:build !windows

package windowstunnel

import (
	"context"
	"fmt"

	"github.com/cacggghp/vk-turn-proxy/pkg/proxy"
)

type wireGuardAttachment struct{}

func attachWireGuard(ctx context.Context, req StartRequest, p *proxy.Proxy) (*wireGuardAttachment, error) {
	return nil, fmt.Errorf("Wintun/WireGuard attach is only available on Windows")
}

func (a *wireGuardAttachment) Close() {}
