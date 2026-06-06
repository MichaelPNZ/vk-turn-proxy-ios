package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/cacggghp/vk-turn-proxy/internal/windowstunnel"
)

type appConfig struct {
	mode             string
	serviceName      string
	requestPath      string
	statusPath       string
	logFile          string
	controlPipe      string
	controlTimeout   time.Duration
	bootstrapTimeout time.Duration
}

func main() {
	cfg := parseFlags()
	if cfg.logFile != "" {
		if err := os.MkdirAll(filepath.Dir(cfg.logFile), 0o755); err != nil {
			log.Fatalf("create log dir: %v", err)
		}
		f, err := os.OpenFile(cfg.logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			log.Fatalf("open logfile: %v", err)
		}
		defer f.Close()
		log.SetOutput(f)
	}

	switch cfg.mode {
	case "validate":
		if err := validate(cfg); err != nil {
			log.Fatalf("validate: %v", err)
		}
	case "run-console":
		if err := runConsole(cfg); err != nil && !errors.Is(err, context.Canceled) {
			log.Fatalf("run-console: %v", err)
		}
	case "service":
		if err := runService(cfg); err != nil {
			log.Fatalf("service: %v", err)
		}
	case "control-start":
		if err := sendControl(cfg, windowstunnel.ControlStart); err != nil {
			log.Fatalf("control-start: %v", err)
		}
	case "control-stop":
		if err := sendControl(cfg, windowstunnel.ControlStop); err != nil {
			log.Fatalf("control-stop: %v", err)
		}
	case "control-status":
		if err := sendControl(cfg, windowstunnel.ControlStatus); err != nil {
			log.Fatalf("control-status: %v", err)
		}
	case "control-logs":
		if err := sendControl(cfg, windowstunnel.ControlLogs); err != nil {
			log.Fatalf("control-logs: %v", err)
		}
	default:
		log.Fatalf("unknown -mode %q; use validate, run-console, service, control-start, control-stop, control-status, or control-logs", cfg.mode)
	}
}

func parseFlags() appConfig {
	var cfg appConfig
	flag.StringVar(&cfg.mode, "mode", "run-console", "validate | run-console | service | control-start | control-stop | control-status | control-logs")
	flag.StringVar(&cfg.serviceName, "service-name", "VKTurnProxyTunnel", "Windows service name")
	flag.StringVar(&cfg.requestPath, "request", "", "path to WindowsTunnelStartRequest JSON")
	flag.StringVar(&cfg.statusPath, "status-file", defaultStatusPath(), "path to write status JSON")
	flag.StringVar(&cfg.logFile, "logfile", "", "append logs to this file")
	flag.StringVar(&cfg.controlPipe, "control-pipe", "", "Windows named pipe for service control")
	flag.DurationVar(&cfg.controlTimeout, "control-timeout", 30*time.Second, "timeout for control client commands")
	flag.DurationVar(&cfg.bootstrapTimeout, "bootstrap-timeout", 120*time.Second, "VK/TURN bootstrap timeout")
	flag.Parse()
	if cfg.controlPipe == "" {
		cfg.controlPipe = windowstunnel.DefaultControlPipeName(cfg.serviceName)
	}
	return cfg
}

func validate(cfg appConfig) error {
	req, err := loadRequest(cfg.requestPath)
	if err != nil {
		return err
	}
	if err := windowstunnel.ValidateStartRequest(req); err != nil {
		return err
	}
	raw, _ := json.MarshalIndent(windowstunnel.BaseStatus(req, "validated"), "", "  ")
	fmt.Println(string(raw))
	return nil
}

func runConsole(cfg appConfig) error {
	req, err := loadRequest(cfg.requestPath)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return windowstunnel.RunBootstrap(ctx, windowstunnel.RunnerConfig{
		Request:          req,
		StatusPath:       cfg.statusPath,
		BootstrapTimeout: cfg.bootstrapTimeout,
	})
}

func runService(cfg appConfig) error {
	if cfg.requestPath == "" {
		server := windowstunnel.NewControlServer(windowstunnel.ControlServerConfig{
			StatusPath:       cfg.statusPath,
			LogPath:          cfg.logFile,
			BootstrapTimeout: cfg.bootstrapTimeout,
		})
		return runPlatformService(cfg.serviceName, func(ctx context.Context) error {
			log.Printf("starting Windows control pipe: %s", cfg.controlPipe)
			return windowstunnel.RunControlPipeServer(ctx, cfg.controlPipe, server)
		})
	}
	req, err := loadRequest(cfg.requestPath)
	if err != nil {
		return err
	}
	return runPlatformService(cfg.serviceName, func(ctx context.Context) error {
		return windowstunnel.RunBootstrap(ctx, windowstunnel.RunnerConfig{
			Request:          req,
			StatusPath:       cfg.statusPath,
			BootstrapTimeout: cfg.bootstrapTimeout,
		})
	})
}

func sendControl(cfg appConfig, command string) error {
	var req *windowstunnel.StartRequest
	if command == windowstunnel.ControlStart {
		loaded, err := loadRequest(cfg.requestPath)
		if err != nil {
			return err
		}
		req = &loaded
	}
	ctx, cancel := context.WithTimeout(context.Background(), cfg.controlTimeout)
	defer cancel()
	response, err := windowstunnel.SendControlCommand(ctx, cfg.controlPipe, windowstunnel.ControlCommand{
		Command: command,
		Request: req,
	})
	if err != nil {
		return err
	}
	raw, _ := json.MarshalIndent(response, "", "  ")
	fmt.Println(string(raw))
	if !response.OK {
		return errors.New(response.Error)
	}
	return nil
}

func loadRequest(path string) (windowstunnel.StartRequest, error) {
	if path == "" {
		return windowstunnel.StartRequest{}, fmt.Errorf("-request is required")
	}
	return windowstunnel.LoadStartRequest(path)
}
