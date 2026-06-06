//go:build !windows

package windowstunnel

import (
	"context"
	"fmt"
)

func RunControlPipeServer(ctx context.Context, pipeName string, server *ControlServer) error {
	return fmt.Errorf("Windows named-pipe control server is only available on Windows")
}

func SendControlCommand(ctx context.Context, pipeName string, command ControlCommand) (ControlResponse, error) {
	return ControlResponse{}, fmt.Errorf("Windows named-pipe control client is only available on Windows")
}
