package windowstunnel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	ControlStart  = "start"
	ControlStop   = "stop"
	ControlStatus = "status"
	ControlLogs   = "logs"
)

type ControlCommand struct {
	Command  string        `json:"command"`
	Request  *StartRequest `json:"request,omitempty"`
	MaxBytes int64         `json:"maxBytes,omitempty"`
}

type ControlResponse struct {
	OK     bool       `json:"ok"`
	Status *Status    `json:"status,omitempty"`
	Logs   *LogExport `json:"logs,omitempty"`
	Error  string     `json:"error,omitempty"`
}

type LogExport struct {
	StatusPath string `json:"statusPath,omitempty"`
	StatusJSON string `json:"statusJson,omitempty"`
	LogPath    string `json:"logPath,omitempty"`
	LogTail    string `json:"logTail,omitempty"`
	MaxBytes   int64  `json:"maxBytes"`
	Truncated  bool   `json:"truncated"`
}

type ControlServerConfig struct {
	StatusPath       string
	LogPath          string
	BootstrapTimeout time.Duration
	Runner           func(context.Context, RunnerConfig) error
}

type ControlServer struct {
	statusPath       string
	logPath          string
	bootstrapTimeout time.Duration
	runner           func(context.Context, RunnerConfig) error

	mu      sync.Mutex
	cancel  context.CancelFunc
	done    chan struct{}
	request StartRequest
}

func DefaultControlPipeName(serviceName string) string {
	name := strings.TrimSpace(serviceName)
	if name == "" {
		name = "VKTurnProxyTunnel"
	}
	return `\\.\pipe\` + name
}

func NewControlServer(cfg ControlServerConfig) *ControlServer {
	runner := cfg.Runner
	if runner == nil {
		runner = RunBootstrap
	}
	if cfg.BootstrapTimeout <= 0 {
		cfg.BootstrapTimeout = 120 * time.Second
	}
	return &ControlServer{
		statusPath:       cfg.StatusPath,
		logPath:          cfg.LogPath,
		bootstrapTimeout: cfg.BootstrapTimeout,
		runner:           runner,
	}
}

func (s *ControlServer) Serve(ctx context.Context, listener net.Listener) error {
	context.AfterFunc(ctx, func() {
		_ = s.stop()
		_ = listener.Close()
	})
	for {
		conn, err := listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) || ctx.Err() != nil {
				return ctx.Err()
			}
			return err
		}
		go s.handleConn(conn)
	}
}

func (s *ControlServer) handleConn(conn net.Conn) {
	defer conn.Close()
	var command ControlCommand
	if err := json.NewDecoder(conn).Decode(&command); err != nil {
		writeControlResponse(conn, ControlResponse{OK: false, Error: "decode command: " + err.Error()})
		return
	}
	writeControlResponse(conn, s.HandleCommand(command))
}

func (s *ControlServer) HandleCommand(command ControlCommand) ControlResponse {
	switch strings.ToLower(strings.TrimSpace(command.Command)) {
	case ControlStart:
		if command.Request == nil {
			return controlError("start requires request")
		}
		return s.start(*command.Request)
	case ControlStop:
		return s.stop()
	case ControlStatus:
		return s.status()
	case ControlLogs:
		return s.logs(command.MaxBytes)
	default:
		return controlError(fmt.Sprintf("unknown command %q", command.Command))
	}
}

func (s *ControlServer) start(req StartRequest) ControlResponse {
	if err := ValidateStartRequest(req); err != nil {
		return controlError(err.Error())
	}

	s.mu.Lock()
	if s.cancel != nil {
		status := BaseStatus(s.request, "already_running")
		s.mu.Unlock()
		return ControlResponse{OK: false, Status: &status, Error: "tunnel is already running"}
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	s.cancel = cancel
	s.done = done
	s.request = req
	s.mu.Unlock()

	status := BaseStatus(req, "start_requested")
	_ = WriteStatus(s.statusPath, status)

	go func() {
		defer close(done)
		err := s.runner(ctx, RunnerConfig{
			Request:          req,
			StatusPath:       s.statusPath,
			BootstrapTimeout: s.bootstrapTimeout,
		})
		if errors.Is(err, context.Canceled) {
			_ = WriteStatus(s.statusPath, BaseStatus(req, "stopped"))
		} else if err != nil {
			_ = WriteStatus(s.statusPath, statusWithError(req, "failed", err))
		}

		s.mu.Lock()
		if s.done == done {
			s.cancel = nil
			s.done = nil
			s.request = StartRequest{}
		}
		s.mu.Unlock()
	}()

	return ControlResponse{OK: true, Status: &status}
}

func (s *ControlServer) stop() ControlResponse {
	s.mu.Lock()
	cancel := s.cancel
	req := s.request
	s.mu.Unlock()

	if cancel == nil {
		status, err := LoadStatus(s.statusPath)
		if err == nil {
			return ControlResponse{OK: true, Status: &status}
		}
		stopped := Status{State: "stopped", UpdatedAt: time.Now().UTC().Format(time.RFC3339)}
		return ControlResponse{OK: true, Status: &stopped}
	}
	cancel()
	status := BaseStatus(req, "stop_requested")
	_ = WriteStatus(s.statusPath, status)
	return ControlResponse{OK: true, Status: &status}
}

func (s *ControlServer) status() ControlResponse {
	status, err := LoadStatus(s.statusPath)
	if err == nil {
		return ControlResponse{OK: true, Status: &status}
	}
	if errors.Is(err, os.ErrNotExist) {
		stopped := Status{State: "stopped", UpdatedAt: time.Now().UTC().Format(time.RFC3339)}
		return ControlResponse{OK: true, Status: &stopped}
	}
	return controlError(err.Error())
}

func (s *ControlServer) logs(maxBytes int64) ControlResponse {
	if maxBytes <= 0 {
		maxBytes = 256 * 1024
	}
	export := LogExport{
		StatusPath: s.statusPath,
		LogPath:    s.logPath,
		MaxBytes:   maxBytes,
	}
	if strings.TrimSpace(s.statusPath) != "" {
		raw, err := os.ReadFile(s.statusPath)
		if err == nil {
			export.StatusJSON = string(raw)
		} else if !errors.Is(err, os.ErrNotExist) {
			return controlError("read status: " + err.Error())
		}
	}
	if strings.TrimSpace(s.logPath) != "" {
		raw, truncated, err := tailFileWithTruncation(s.logPath, maxBytes)
		if err == nil {
			export.LogTail = raw
			export.Truncated = truncated
		} else if !errors.Is(err, os.ErrNotExist) {
			return controlError("read log: " + err.Error())
		}
	}
	return ControlResponse{OK: true, Logs: &export}
}

func LoadStatus(path string) (Status, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Status{}, err
	}
	var status Status
	if err := json.Unmarshal(raw, &status); err != nil {
		return Status{}, err
	}
	return status, nil
}

func tailFileWithTruncation(path string, maxBytes int64) (string, bool, error) {
	if maxBytes <= 0 {
		maxBytes = 256 * 1024
	}
	file, err := os.Open(path)
	if err != nil {
		return "", false, err
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return "", false, err
	}
	size := info.Size()
	offset := int64(0)
	truncated := false
	if size > maxBytes {
		offset = size - maxBytes
		truncated = true
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return "", false, err
	}
	raw, err := io.ReadAll(file)
	if err != nil {
		return "", false, err
	}
	return string(raw), truncated, nil
}

func writeControlResponse(w io.Writer, response ControlResponse) {
	_ = json.NewEncoder(w).Encode(response)
}

func controlError(message string) ControlResponse {
	return ControlResponse{OK: false, Error: message}
}
