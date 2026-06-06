package windowstunnel

import (
	"strings"
	"testing"
)

func TestValidateStartRequest(t *testing.T) {
	req := validRequest()
	if err := ValidateStartRequest(req); err != nil {
		t.Fatalf("ValidateStartRequest() error = %v", err)
	}
}

func TestValidateStartRequestCatchesPeerMismatch(t *testing.T) {
	req := validRequest()
	req.PeerAddress = "142.252.220.91:56014"

	err := ValidateStartRequest(req)
	if err == nil {
		t.Fatal("ValidateStartRequest() error = nil")
	}
	if !strings.Contains(err.Error(), "does not match peerAddress") {
		t.Fatalf("ValidateStartRequest() error = %v", err)
	}
}

func TestParseProxyRequestDefaultsNumConns(t *testing.T) {
	cfg, err := ParseProxyRequest(`{
		"peer_addr":"142.252.220.91:56004",
		"vk_link":"https://vk.com/call/join/test",
		"use_srtp":true
	}`)
	if err != nil {
		t.Fatalf("ParseProxyRequest() error = %v", err)
	}
	if cfg.NumConns != 1 {
		t.Fatalf("NumConns = %d, want 1", cfg.NumConns)
	}
}

func validRequest() StartRequest {
	return StartRequest{
		SchemaVersion: 1,
		ServiceName:   "VKTurnProxyTunnel",
		AdapterName:   "VK Turn Proxy",
		ProfileID:     "windows-runtime",
		ProfileName:   "Windows Runtime",
		PeerAddress:   "142.252.220.91:56004",
		InterfaceAddr: "10.88.0.2/32",
		DNSServers:    []string{"1.1.1.1"},
		AllowedIPs:    []string{"0.0.0.0/0"},
		WireGuardUAPI: "private_key=001122\nreplace_peers=true\npublic_key=334455\nendpoint=142.252.220.91:56004\nallowed_ip=0.0.0.0/0",
		ProxyJSON: `{
			"peer_addr":"142.252.220.91:56004",
			"vk_link":"https://vk.com/call/join/test",
			"num_conns":10,
			"use_dtls":true,
			"use_udp":false,
			"use_srtp":true,
			"use_wrap_a":false
		}`,
	}
}
