//go:build windows

package main

import (
	"context"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows/svc"
)

type serviceHandler struct {
	run func(context.Context) error
}

func runPlatformService(serviceName string, run func(context.Context) error) error {
	return svc.Run(serviceName, serviceHandler{run: run})
}

func (h serviceHandler) Execute(args []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	status <- svc.Status{State: svc.StartPending}
	errCh := make(chan error, 1)
	go func() {
		errCh <- h.run(ctx)
	}()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}

	for {
		select {
		case err := <-errCh:
			if err != nil && err != context.Canceled {
				status <- svc.Status{State: svc.StopPending}
				return false, 1
			}
			status <- svc.Status{State: svc.StopPending}
			return false, 0
		case request := <-requests:
			switch request.Cmd {
			case svc.Interrogate:
				status <- request.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				cancel()
			default:
				status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
			}
		}
	}
}

func defaultStatusPath() string {
	programData := os.Getenv("ProgramData")
	if programData == "" {
		programData = `C:\ProgramData`
	}
	return filepath.Join(programData, "VKTurnProxy", "status.json")
}
