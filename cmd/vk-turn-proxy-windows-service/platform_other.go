//go:build !windows

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

func runPlatformService(serviceName string, run func(context.Context) error) error {
	return fmt.Errorf("Windows service mode is only available on Windows; use -mode run-console on this host")
}

func defaultStatusPath() string {
	return filepath.Join(os.TempDir(), "vkturnproxy-status.json")
}
