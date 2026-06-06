package windowstunnel

import (
	"context"
	"encoding/hex"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/cacggghp/vk-turn-proxy/pkg/proxy"
)

type RunnerConfig struct {
	Request          StartRequest
	StatusPath       string
	BootstrapTimeout time.Duration
}

func RunBootstrap(ctx context.Context, cfg RunnerConfig) error {
	req := cfg.Request
	if cfg.BootstrapTimeout <= 0 {
		cfg.BootstrapTimeout = 120 * time.Second
	}
	if err := ValidateStartRequest(req); err != nil {
		_ = WriteStatus(cfg.StatusPath, statusWithError(req, "invalid_request", err))
		return err
	}

	proxyReq, err := ParseProxyRequest(req.ProxyJSON)
	if err != nil {
		_ = WriteStatus(cfg.StatusPath, statusWithError(req, "invalid_proxy_json", err))
		return err
	}

	pcfg, err := proxyConfigFromRequest(proxyReq)
	if err != nil {
		_ = WriteStatus(cfg.StatusPath, statusWithError(req, "invalid_proxy_config", err))
		return err
	}

	p := proxy.NewProxy(pcfg)
	startedAt := time.Now().UTC()
	status := BaseStatus(req, "starting_proxy")
	status.StartedAt = startedAt.Format(time.RFC3339)
	status.Blockers = []string{
		"Waiting for VK/TURN bootstrap before attaching Wintun/WireGuard.",
	}
	if err := WriteStatus(cfg.StatusPath, status); err != nil {
		return err
	}

	errCh := make(chan error, 1)
	go func() {
		errCh <- p.Start()
	}()

	if err := p.WaitBootstrap(cfg.BootstrapTimeout); err != nil {
		p.StopWithTimeout(2 * time.Second)
		_ = WriteStatus(cfg.StatusPath, statusWithError(req, "bootstrap_failed", err))
		return err
	}

	writeProxyStatus(cfg.StatusPath, req, p, startedAt, "bootstrap_ready")
	attachment, err := attachWireGuard(ctx, req, p)
	if err != nil {
		p.StopWithTimeout(2 * time.Second)
		_ = WriteStatus(cfg.StatusPath, statusWithError(req, "wireguard_attach_failed", err))
		return err
	}
	defer attachment.Close()
	writeProxyStatus(cfg.StatusPath, req, p, startedAt, "wireguard_attached")

	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	defer p.StopWithTimeout(2 * time.Second)

	for {
		select {
		case <-ctx.Done():
			writeProxyStatus(cfg.StatusPath, req, p, startedAt, "stopping")
			return ctx.Err()
		case err := <-errCh:
			if err != nil {
				_ = WriteStatus(cfg.StatusPath, statusWithError(req, "proxy_failed", err))
				return err
			}
			writeProxyStatus(cfg.StatusPath, req, p, startedAt, "proxy_stopped")
			return nil
		case <-ticker.C:
			writeProxyStatus(cfg.StatusPath, req, p, startedAt, "wireguard_attached")
		}
	}
}

func proxyConfigFromRequest(req ProxyRequest) (proxy.Config, error) {
	wrapKey, err := decodeWrapKey(req.UseWrap, req.WrapKeyHex)
	if err != nil {
		return proxy.Config{}, err
	}
	return proxy.Config{
		PeerAddr:         req.PeerAddr,
		TurnServer:       req.TurnServer,
		TurnPort:         req.TurnPort,
		VKLink:           req.VKLink,
		UseDTLS:          req.UseDTLS,
		UseUDP:           req.UseUDP,
		UseWrap:          req.UseWrap,
		WrapKey:          wrapKey,
		UseSrtp:          req.UseSrtp,
		UseWrapA:         req.UseWrapA,
		WrapAPassword:    req.WrapAPassword,
		DeviceID:         req.DeviceID,
		NumConns:         req.NumConns,
		CredPoolCooldown: time.Duration(req.CredPoolCooldownSeconds) * time.Second,
	}, nil
}

func decodeWrapKey(useWrap bool, hexStr string) ([]byte, error) {
	if !useWrap {
		return nil, nil
	}
	normalized := strings.Map(func(r rune) rune {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			return -1
		}
		return r
	}, hexStr)
	key, err := hex.DecodeString(normalized)
	if err != nil {
		return nil, fmt.Errorf("wrap_key_hex is invalid: %w", err)
	}
	if len(key) != 32 {
		return nil, fmt.Errorf("wrap_key_hex decodes to %d bytes, expected 32", len(key))
	}
	return key, nil
}

func writeProxyStatus(path string, req StartRequest, p *proxy.Proxy, startedAt time.Time, state string) {
	stats := p.GetStats()
	status := BaseStatus(req, state)
	status.StartedAt = startedAt.Format(time.RFC3339)
	status.BootstrapReady = true
	status.WireGuardConfigured = state == "wireguard_attached" || state == "stopping" || state == "proxy_stopped"
	status.ProxyStats = &ProxyStats{
		TxBytes:           stats.TxBytes,
		RxBytes:           stats.RxBytes,
		RequestedConns:    stats.RequestedConns,
		ActiveConns:       stats.ActiveConns,
		TotalConns:        stats.TotalConns,
		TurnRTTms:         stats.TurnRTTms,
		DTLSHandshakeMs:   stats.DTLSHandshakeMs,
		LastHandshakeSec:  stats.LastHandshakeSec,
		Reconnects:        stats.Reconnects,
		CredPoolFilled:    stats.CredPoolFilled,
		CredPoolWithCreds: stats.CredPoolWithCreds,
		CredPoolSize:      stats.CredPoolSize,
		TunnelUptimeSec:   stats.TunnelUptimeSec,
	}
	if err := WriteStatus(path, status); err != nil {
		log.Printf("windows tunnel status write failed: %v", err)
	}
}

func statusWithError(req StartRequest, state string, err error) Status {
	status := BaseStatus(req, state)
	status.LastError = err.Error()
	return status
}
