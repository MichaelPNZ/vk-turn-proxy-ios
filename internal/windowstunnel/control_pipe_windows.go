//go:build windows

package windowstunnel

import (
	"context"
	"encoding/json"
	"net"

	"github.com/Microsoft/go-winio"
)

func RunControlPipeServer(ctx context.Context, pipeName string, server *ControlServer) error {
	listener, err := winio.ListenPipe(pipeName, nil)
	if err != nil {
		return err
	}
	return server.Serve(ctx, listener)
}

func SendControlCommand(ctx context.Context, pipeName string, command ControlCommand) (ControlResponse, error) {
	conn, err := winio.DialPipeContext(ctx, pipeName)
	if err != nil {
		return ControlResponse{}, err
	}
	defer conn.Close()
	return sendControlCommand(conn, command)
}

func sendControlCommand(conn net.Conn, command ControlCommand) (ControlResponse, error) {
	if err := json.NewEncoder(conn).Encode(command); err != nil {
		return ControlResponse{}, err
	}
	var response ControlResponse
	if err := json.NewDecoder(conn).Decode(&response); err != nil {
		return ControlResponse{}, err
	}
	return response, nil
}
