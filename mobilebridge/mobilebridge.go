package mobilebridge

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/device"

	"github.com/cacggghp/vk-turn-proxy/pkg/proxy"
	"github.com/cacggghp/vk-turn-proxy/pkg/turnbind"
)

type tunnelEntry struct {
	device *device.Device
	proxy  *proxy.Proxy
	bind   *turnbind.TURNBind
}

var (
	tunnels   = map[int32]*tunnelEntry{}
	tunnelsMu sync.Mutex
	nextID    int32 = 1
)

type proxyConfig struct {
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

type SocketProtector interface {
	Protect(fd int32) bool
}

func SetSocketProtector(protector SocketProtector) {
	if protector == nil {
		proxy.SetSocketProtector(nil)
		return
	}
	proxy.SetSocketProtector(func(fd int) bool {
		return protector.Protect(int32(fd))
	})
}

func StartBootstrap(proxyConfigJSON string) int32 {
	pcfg, err := parseProxyConfig(proxyConfigJSON)
	if err != nil {
		log.Printf("mobilebridge: StartBootstrap config error: %v", err)
		return -1
	}

	if len(pcfg.VKHostIPs) > 0 {
		proxy.SetVKHostIPs(pcfg.VKHostIPs)
	}
	proxy.SetForceLegacyCaptcha(pcfg.ForceLegacyCaptcha)

	wrapKey, wrapErr := decodeWrapKey(pcfg.UseWrap, pcfg.WrapKeyHex)
	if wrapErr != nil {
		log.Printf("mobilebridge: invalid WRAP key, disabling WRAP: %v", wrapErr)
		pcfg.UseWrap = false
	}

	p := proxy.NewProxy(proxy.Config{
		PeerAddr:         pcfg.PeerAddr,
		TurnServer:       pcfg.TurnServer,
		TurnPort:         pcfg.TurnPort,
		VKLink:           pcfg.VKLink,
		UseDTLS:          pcfg.UseDTLS,
		UseUDP:           pcfg.UseUDP,
		UseWrap:          pcfg.UseWrap,
		WrapKey:          wrapKey,
		UseSrtp:          pcfg.UseSrtp,
		UseWrapA:         pcfg.UseWrapA,
		WrapAPassword:    pcfg.WrapAPassword,
		DeviceID:         pcfg.DeviceID,
		NumConns:         pcfg.NumConns,
		CredPoolCooldown: time.Duration(pcfg.CredPoolCooldownSeconds) * time.Second,
	})

	go func() {
		if err := p.Start(); err != nil {
			log.Printf("mobilebridge: proxy.Start failed: %v", err)
		}
	}()

	tunnelsMu.Lock()
	id := nextID
	nextID++
	tunnels[id] = &tunnelEntry{proxy: p}
	tunnelsMu.Unlock()

	log.Printf("mobilebridge: bootstrap started handle=%d", id)
	return id
}

func WaitBootstrapReady(tunnelHandle int32, timeoutMs int32) int32 {
	entry := getTunnel(tunnelHandle)
	if entry == nil || entry.proxy == nil {
		return -1
	}
	err := entry.proxy.WaitBootstrap(time.Duration(timeoutMs) * time.Millisecond)
	if err == nil {
		return 1
	}
	if strings.Contains(err.Error(), "bootstrap timeout") {
		return 0
	}
	log.Printf("mobilebridge: bootstrap failed handle=%d err=%v", tunnelHandle, err)
	return -1
}

func AttachWireGuard(tunnelHandle int32, wgConfigSettings string, tunFd int32) int32 {
	entry := getTunnel(tunnelHandle)
	if entry == nil || entry.proxy == nil {
		return -1
	}
	if entry.device != nil {
		return -2
	}

	bind := turnbind.NewTURNBind(entry.proxy)
	dupFd, err := unix.Dup(int(tunFd))
	if err != nil {
		log.Printf("mobilebridge: dup fd failed: %v", err)
		return -3
	}
	tunDev, err := createTunDeviceFromFD(dupFd)
	if err != nil {
		_ = unix.Close(dupFd)
		log.Printf("mobilebridge: create TUN device from fd failed: %v", err)
		return -4
	}

	dev := device.NewDevice(tunDev, bind, device.NewLogger(device.LogLevelVerbose, "(vkturn-android) "))
	if err := dev.IpcSet(wgConfigSettings); err != nil {
		log.Printf("mobilebridge: IpcSet failed: %v", err)
		dev.Close()
		return -5
	}
	if err := dev.Up(); err != nil {
		log.Printf("mobilebridge: device Up failed: %v", err)
		dev.Close()
		return -6
	}

	tunnelsMu.Lock()
	if entry.device != nil {
		tunnelsMu.Unlock()
		dev.Close()
		return -2
	}
	entry.device = dev
	entry.bind = bind
	tunnelsMu.Unlock()

	log.Printf("mobilebridge: WireGuard attached handle=%d", tunnelHandle)
	return 1
}

func TurnOff(tunnelHandle int32) {
	tunnelsMu.Lock()
	entry, ok := tunnels[tunnelHandle]
	delete(tunnels, tunnelHandle)
	tunnelsMu.Unlock()
	if !ok {
		return
	}
	if entry.proxy != nil {
		entry.proxy.StopWithTimeout(2 * time.Second)
	}
	if entry.device != nil {
		entry.device.Close()
	}
}

func GetStats(tunnelHandle int32) string {
	entry := getTunnel(tunnelHandle)
	if entry == nil || entry.proxy == nil {
		return "{}"
	}
	stats, err := json.Marshal(entry.proxy.GetStats())
	if err != nil {
		return "{}"
	}
	return string(stats)
}

func Version() string {
	return "vkturn-mobilebridge-0.1.0"
}

func getTunnel(tunnelHandle int32) *tunnelEntry {
	tunnelsMu.Lock()
	defer tunnelsMu.Unlock()
	return tunnels[tunnelHandle]
}

func parseProxyConfig(raw string) (proxyConfig, error) {
	var cfg proxyConfig
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
	return cfg, nil
}

func decodeWrapKey(useWrap bool, hexStr string) ([]byte, error) {
	if !useWrap {
		return nil, nil
	}
	hexStr = strings.Map(func(r rune) rune {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			return -1
		}
		return r
	}, hexStr)
	if hexStr == "" {
		return nil, fmt.Errorf("WRAP enabled but wrap_key_hex is empty")
	}
	key, err := hex.DecodeString(hexStr)
	if err != nil {
		return nil, fmt.Errorf("wrap_key_hex not valid hex: %w", err)
	}
	if len(key) != 32 {
		return nil, fmt.Errorf("wrap_key_hex decodes to %d bytes, need 32", len(key))
	}
	return key, nil
}
