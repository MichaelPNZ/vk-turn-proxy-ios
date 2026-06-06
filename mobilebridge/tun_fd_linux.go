//go:build linux || android

package mobilebridge

import "golang.zx2c4.com/wireguard/tun"

func createTunDeviceFromFD(fd int) (tun.Device, error) {
	device, _, err := tun.CreateUnmonitoredTUNFromFD(fd)
	return device, err
}
