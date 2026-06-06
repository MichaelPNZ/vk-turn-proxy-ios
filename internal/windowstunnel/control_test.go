package windowstunnel

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestControlServerStartStatusStop(t *testing.T) {
	started := make(chan struct{})
	released := make(chan struct{})
	server := NewControlServer(ControlServerConfig{
		StatusPath: t.TempDir() + "/status.json",
		Runner: func(ctx context.Context, cfg RunnerConfig) error {
			close(started)
			<-ctx.Done()
			close(released)
			return ctx.Err()
		},
	})

	start := server.HandleCommand(ControlCommand{
		Command: ControlStart,
		Request: ptr(validRequest()),
	})
	if !start.OK || start.Status == nil || start.Status.State != "start_requested" {
		t.Fatalf("start response = %#v", start)
	}

	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("runner did not start")
	}

	status := server.HandleCommand(ControlCommand{Command: ControlStatus})
	if !status.OK || status.Status == nil {
		t.Fatalf("status response = %#v", status)
	}

	stop := server.HandleCommand(ControlCommand{Command: ControlStop})
	if !stop.OK || stop.Status == nil || stop.Status.State != "stop_requested" {
		t.Fatalf("stop response = %#v", stop)
	}

	select {
	case <-released:
	case <-time.After(time.Second):
		t.Fatal("runner did not stop")
	}
}

func TestControlServerRejectsSecondStart(t *testing.T) {
	server := NewControlServer(ControlServerConfig{
		StatusPath: t.TempDir() + "/status.json",
		Runner: func(ctx context.Context, cfg RunnerConfig) error {
			<-ctx.Done()
			return ctx.Err()
		},
	})
	first := server.HandleCommand(ControlCommand{Command: ControlStart, Request: ptr(validRequest())})
	if !first.OK {
		t.Fatalf("first start failed: %#v", first)
	}
	second := server.HandleCommand(ControlCommand{Command: ControlStart, Request: ptr(validRequest())})
	if second.OK {
		t.Fatalf("second start unexpectedly succeeded: %#v", second)
	}
	_ = server.HandleCommand(ControlCommand{Command: ControlStop})
}

func TestControlServerExportsStatusAndLogTail(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	logPath := filepath.Join(dir, "service.log")
	if err := os.WriteFile(statusPath, []byte(`{"state":"wireguard_attached"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(logPath, []byte("first line\nsecond line\nthird line\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	server := NewControlServer(ControlServerConfig{
		StatusPath: statusPath,
		LogPath:    logPath,
	})
	response := server.HandleCommand(ControlCommand{Command: ControlLogs, MaxBytes: 18})
	if !response.OK || response.Logs == nil {
		t.Fatalf("logs response = %#v", response)
	}
	if !strings.Contains(response.Logs.StatusJSON, "wireguard_attached") {
		t.Fatalf("status json missing in export: %#v", response.Logs)
	}
	if !strings.Contains(response.Logs.LogTail, "third line") {
		t.Fatalf("log tail missing latest line: %#v", response.Logs)
	}
	if !response.Logs.Truncated {
		t.Fatalf("expected truncated log export: %#v", response.Logs)
	}
}

func TestTailFileWithTruncation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tail.log")
	if err := os.WriteFile(path, []byte("abcdef"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, truncated, err := tailFileWithTruncation(path, 3)
	if err != nil {
		t.Fatal(err)
	}
	if got != "def" || !truncated {
		t.Fatalf("tail = %q truncated=%v, want def true", got, truncated)
	}
}

func ptr[T any](value T) *T {
	return &value
}
