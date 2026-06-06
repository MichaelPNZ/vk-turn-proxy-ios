//go:build !linux && !android

package mobilebridge

import (
	"os"

	"golang.zx2c4.com/wireguard/tun"
)

func createTunDeviceFromFD(fd int) (tun.Device, error) {
	tunFile := os.NewFile(uintptr(fd), "/dev/tun")
	device, err := tun.CreateTUNFromFile(tunFile, 0)
	if err != nil {
		_ = tunFile.Close()
	}
	return device, err
}
