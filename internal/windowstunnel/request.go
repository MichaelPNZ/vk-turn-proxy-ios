package windowstunnel

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type StartRequest struct {
	SchemaVersion int      `json:"schemaVersion"`
	ServiceName   string   `json:"serviceName"`
	AdapterName   string   `json:"adapterName"`
	ProfileID     string   `json:"profileId"`
	ProfileName   string   `json:"profileName"`
	PeerAddress   string   `json:"peerAddress"`
	InterfaceAddr string   `json:"interfaceAddress"`
	DNSServers    []string `json:"dnsServers"`
	AllowedIPs    []string `json:"allowedIps"`
	WireGuardUAPI string   `json:"wireGuardUapi"`
	ProxyJSON     string   `json:"proxyJson"`
}

type ProxyRequest struct {
	VKLink                  string              `json:"vk_link"`
	PeerAddr                string              `json:"peer_addr"`
	TurnServer              string              `json:"turn_server,omitempty"`
	TurnPort                string              `json:"turn_port,omitempty"`
	UseDTLS                 bool                `json:"use_dtls"`
	UseUDP                  bool                `json:"use_udp"`
	UseWrap                 bool                `json:"use_wrap"`
	WrapKeyHex              string              `json:"wrap_key_hex"`
	UseSrtp                 bool                `json:"use_srtp"`
	UseWrapA                bool                `json:"use_wrap_a"`
	WrapAPassword           string              `json:"wrap_a_password,omitempty"`
	DeviceID                string              `json:"device_id,omitempty"`
	NumConns                int                 `json:"num_conns,omitempty"`
	CredPoolCooldownSeconds int                 `json:"cred_pool_cooldown_seconds,omitempty"`
	VKHostIPs               map[string][]string `json:"vk_host_ips,omitempty"`
	ForceLegacyCaptcha      bool                `json:"force_legacy_captcha,omitempty"`
}

type Status struct {
	State               string       `json:"state"`
	ServiceName         string       `json:"serviceName,omitempty"`
	AdapterName         string       `json:"adapterName,omitempty"`
	ProfileID           string       `json:"profileId,omitempty"`
	ProfileName         string       `json:"profileName,omitempty"`
	PeerAddress         string       `json:"peerAddress,omitempty"`
	StartedAt           string       `json:"startedAt,omitempty"`
	UpdatedAt           string       `json:"updatedAt"`
	LastError           string       `json:"lastError,omitempty"`
	BootstrapReady      bool         `json:"bootstrapReady"`
	WireGuardConfigured bool         `json:"wireGuardConfigured"`
	ProxyStats          *ProxyStats  `json:"proxyStats,omitempty"`
	Blockers            []string     `json:"blockers,omitempty"`
	Request             *RequestInfo `json:"request,omitempty"`
}

type RequestInfo struct {
	InterfaceAddress string   `json:"interfaceAddress"`
	DNSServers       []string `json:"dnsServers"`
	AllowedIPs       []string `json:"allowedIps"`
	ProxyJSONBytes   int      `json:"proxyJsonBytes"`
	WireGuardBytes   int      `json:"wireGuardUapiBytes"`
}

type ProxyStats struct {
	TxBytes           int64   `json:"tx_bytes"`
	RxBytes           int64   `json:"rx_bytes"`
	RequestedConns    int32   `json:"requested_conns"`
	ActiveConns       int32   `json:"active_conns"`
	TotalConns        int32   `json:"total_conns"`
	TurnRTTms         float64 `json:"turn_rtt_ms"`
	DTLSHandshakeMs   float64 `json:"dtls_handshake_ms"`
	LastHandshakeSec  int64   `json:"last_handshake_sec"`
	Reconnects        int64   `json:"reconnects"`
	CredPoolFilled    int32   `json:"cred_pool_filled"`
	CredPoolWithCreds int32   `json:"cred_pool_with_creds"`
	CredPoolSize      int32   `json:"cred_pool_size"`
	TunnelUptimeSec   int64   `json:"tunnel_uptime_sec"`
}

func LoadStartRequest(path string) (StartRequest, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return StartRequest{}, err
	}
	var req StartRequest
	if err := json.Unmarshal(raw, &req); err != nil {
		return StartRequest{}, err
	}
	return req, nil
}

func WriteStatus(path string, status Status) error {
	status.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	raw, err := json.MarshalIndent(status, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, append(raw, '\n'), 0o644)
}

func ValidateStartRequest(req StartRequest) error {
	var problems []string
	if req.SchemaVersion != 1 {
		problems = append(problems, fmt.Sprintf("schemaVersion must be 1, got %d", req.SchemaVersion))
	}
	if strings.TrimSpace(req.ServiceName) == "" {
		problems = append(problems, "serviceName is required")
	}
	if strings.TrimSpace(req.AdapterName) == "" {
		problems = append(problems, "adapterName is required")
	}
	if strings.TrimSpace(req.ProfileID) == "" {
		problems = append(problems, "profileId is required")
	}
	if _, _, err := net.SplitHostPort(req.PeerAddress); err != nil {
		problems = append(problems, fmt.Sprintf("peerAddress must be host:port: %v", err))
	}
	if _, _, err := net.ParseCIDR(req.InterfaceAddr); err != nil {
		problems = append(problems, fmt.Sprintf("interfaceAddress must be CIDR: %v", err))
	}
	for _, dns := range req.DNSServers {
		if net.ParseIP(dns) == nil {
			problems = append(problems, fmt.Sprintf("dnsServers contains invalid IP: %s", dns))
		}
	}
	if len(req.AllowedIPs) == 0 {
		problems = append(problems, "allowedIps must not be empty")
	}
	for _, cidr := range req.AllowedIPs {
		if _, _, err := net.ParseCIDR(cidr); err != nil {
			problems = append(problems, fmt.Sprintf("allowedIps contains invalid CIDR %q: %v", cidr, err))
		}
	}
	if strings.TrimSpace(req.WireGuardUAPI) == "" {
		problems = append(problems, "wireGuardUapi is required for the current SRTP/WireGuard mode")
	}
	proxyReq, err := ParseProxyRequest(req.ProxyJSON)
	if err != nil {
		problems = append(problems, fmt.Sprintf("proxyJson is invalid: %v", err))
	} else if proxyReq.PeerAddr != req.PeerAddress {
		problems = append(problems, fmt.Sprintf("proxyJson peer_addr %q does not match peerAddress %q", proxyReq.PeerAddr, req.PeerAddress))
	}
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

func ParseProxyRequest(raw string) (ProxyRequest, error) {
	var cfg ProxyRequest
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		return cfg, err
	}
	if cfg.PeerAddr == "" {
		return cfg, fmt.Errorf("peer_addr is required")
	}
	if cfg.VKLink == "" {
		return cfg, fmt.Errorf("vk_link is required")
	}
	if cfg.NumConns <= 0 {
		cfg.NumConns = 1
	}
	if cfg.UseWrap {
		key, err := hex.DecodeString(strings.TrimSpace(cfg.WrapKeyHex))
		if err != nil {
			return cfg, fmt.Errorf("wrap_key_hex is invalid: %w", err)
		}
		if len(key) != 32 {
			return cfg, fmt.Errorf("wrap_key_hex decodes to %d bytes, expected 32", len(key))
		}
	}
	return cfg, nil
}

func BaseStatus(req StartRequest, state string) Status {
	return Status{
		State:       state,
		ServiceName: req.ServiceName,
		AdapterName: req.AdapterName,
		ProfileID:   req.ProfileID,
		ProfileName: req.ProfileName,
		PeerAddress: req.PeerAddress,
		UpdatedAt:   time.Now().UTC().Format(time.RFC3339),
		Request: &RequestInfo{
			InterfaceAddress: req.InterfaceAddr,
			DNSServers:       req.DNSServers,
			AllowedIPs:       req.AllowedIPs,
			ProxyJSONBytes:   len([]byte(req.ProxyJSON)),
			WireGuardBytes:   len([]byte(req.WireGuardUAPI)),
		},
	}
}
