//go:build windows

package windowstunnel

import (
	"context"
	"fmt"
	"log"
	"net"
	"os/exec"
	"strings"

	"github.com/cacggghp/vk-turn-proxy/pkg/proxy"
	"github.com/cacggghp/vk-turn-proxy/pkg/turnbind"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

type wireGuardAttachment struct {
	device      *device.Device
	tun         tun.Device
	adapterName string
	routes      []string
}

func attachWireGuard(ctx context.Context, req StartRequest, p *proxy.Proxy) (*wireGuardAttachment, error) {
	tunDev, err := tun.CreateTUN(req.AdapterName, 1280)
	if err != nil {
		return nil, fmt.Errorf("create Wintun adapter %q: %w", req.AdapterName, err)
	}
	realName, err := tunDev.Name()
	if err != nil || strings.TrimSpace(realName) == "" {
		realName = req.AdapterName
	}

	attachment := &wireGuardAttachment{
		tun:         tunDev,
		adapterName: realName,
		routes:      req.AllowedIPs,
	}
	if err := attachment.configureInterface(ctx, req); err != nil {
		attachment.Close()
		return nil, err
	}

	wgDevice := device.NewDevice(
		tunDev,
		turnbind.NewTURNBind(p),
		device.NewLogger(device.LogLevelVerbose, "(vkturn-windows) "),
	)
	attachment.device = wgDevice

	if err := wgDevice.IpcSet(req.WireGuardUAPI); err != nil {
		attachment.Close()
		return nil, fmt.Errorf("apply WireGuard UAPI: %w", err)
	}
	if err := wgDevice.Up(); err != nil {
		attachment.Close()
		return nil, fmt.Errorf("bring WireGuard device up: %w", err)
	}
	return attachment, nil
}

func (a *wireGuardAttachment) configureInterface(ctx context.Context, req StartRequest) error {
	address, ipNet, err := net.ParseCIDR(req.InterfaceAddr)
	if err != nil {
		return fmt.Errorf("parse interface address: %w", err)
	}
	mask := net.IP(ipNet.Mask).String()
	if err := runWindowsNet(ctx, "netsh", "interface", "ipv4", "set", "address",
		fmt.Sprintf("name=%s", a.adapterName),
		"source=static",
		fmt.Sprintf("address=%s", address.String()),
		fmt.Sprintf("mask=%s", mask),
		"gateway=none",
	); err != nil {
		return err
	}
	if len(req.DNSServers) > 0 {
		if err := runWindowsNet(ctx, "netsh", "interface", "ipv4", "set", "dnsservers",
			fmt.Sprintf("name=%s", a.adapterName),
			"source=static",
			fmt.Sprintf("address=%s", req.DNSServers[0]),
			"validate=no",
		); err != nil {
			return err
		}
		for _, dns := range req.DNSServers[1:] {
			if err := runWindowsNet(ctx, "netsh", "interface", "ipv4", "add", "dnsservers",
				fmt.Sprintf("name=%s", a.adapterName),
				fmt.Sprintf("address=%s", dns),
				"validate=no",
			); err != nil {
				return err
			}
		}
	}
	for _, route := range req.AllowedIPs {
		if err := runWindowsNet(ctx, "netsh", "interface", "ipv4", "add", "route",
			fmt.Sprintf("prefix=%s", route),
			fmt.Sprintf("interface=%s", a.adapterName),
			"nexthop=0.0.0.0",
			"store=active",
		); err != nil {
			return err
		}
	}
	return nil
}

func (a *wireGuardAttachment) Close() {
	if a == nil {
		return
	}
	if a.device != nil {
		a.device.Close()
		a.device = nil
	}
	ctx := context.Background()
	for _, route := range a.routes {
		if err := runWindowsNet(ctx, "netsh", "interface", "ipv4", "delete", "route",
			fmt.Sprintf("prefix=%s", route),
			fmt.Sprintf("interface=%s", a.adapterName),
			"nexthop=0.0.0.0",
			"store=active",
		); err != nil {
			log.Printf("windows route cleanup failed for %s: %v", route, err)
		}
	}
	if a.tun != nil {
		if err := a.tun.Close(); err != nil {
			log.Printf("wintun close failed: %v", err)
		}
		a.tun = nil
	}
}

func runWindowsNet(ctx context.Context, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s failed: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return nil
}
