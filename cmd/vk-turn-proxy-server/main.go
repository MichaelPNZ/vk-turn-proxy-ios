package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/cacggghp/vk-turn-proxy/pkg/proxy/srtpwrap"
)

var probePingMagic = []byte{0xff, 'P', 'N', 'G'}

type metrics struct {
	startedAtUnix    int64
	activeSessions   atomic.Int64
	acceptedSessions atomic.Int64
	rejectedSessions atomic.Int64
	closedSessions   atomic.Int64
	acceptErrors     atomic.Int64
	backendErrors    atomic.Int64
	probeEchoes      atomic.Int64
	rxBytes          atomic.Int64
	txBytes          atomic.Int64
	lastActivityUnix atomic.Int64
}

func main() {
	var (
		listen       = flag.String("listen", "0.0.0.0:56000", "listen on ip:port")
		connect      = flag.String("connect", "", "connect to backend ip:port")
		useSrtp      = flag.Bool("srtp", false, "enable DTLS-SRTP listener mode")
		wrapSrtp     = flag.Bool("wrap-srtp", false, "WRAP+SRTP mode is not implemented in this fork command yet")
		wrapKey      = flag.String("wrap-key", "", "reserved for -wrap-srtp compatibility")
		genWrapKey   = flag.Bool("gen-wrap-key", false, "print a fresh 32-byte WRAP key as 64 hex chars and exit")
		logFile      = flag.String("logfile", "", "append logs to this file instead of stdout")
		healthListen = flag.String("health-listen", "127.0.0.1:56080", "admin HTTP listen address for /healthz, /readyz and /metrics; empty disables")
		idleTimeout  = flag.Duration("session-idle-timeout", 30*time.Minute, "session read idle timeout")
		maxSessions  = flag.Int("max-sessions", 1024, "maximum concurrent SRTP sessions; <=0 disables the limit")
	)
	flag.Parse()

	if *genWrapKey {
		key := make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			log.Fatalf("gen wrap key: %v", err)
		}
		fmt.Println(hex.EncodeToString(key))
		return
	}
	if *wrapKey != "" && !*wrapSrtp {
		log.Printf("warning: -wrap-key ignored without -wrap-srtp")
	}
	if *wrapSrtp {
		log.Fatalf("-wrap-srtp is not implemented in this fork command yet; current production iOS path uses -srtp")
	}
	if !*useSrtp {
		log.Fatalf("only -srtp mode is implemented in this fork command")
	}
	if *connect == "" {
		log.Fatalf("-connect is required")
	}
	if *logFile != "" {
		f, err := os.OpenFile(*logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			log.Fatalf("open logfile: %v", err)
		}
		defer f.Close()
		log.SetOutput(f)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	m := &metrics{startedAtUnix: time.Now().Unix()}
	m.lastActivityUnix.Store(m.startedAtUnix)

	if *healthListen != "" {
		if err := startHealthServer(ctx, *healthListen, *connect, m); err != nil {
			log.Fatalf("%v", err)
		}
	}

	if err := runSrtpServer(ctx, *listen, *connect, *idleTimeout, *maxSessions, m); err != nil && !errors.Is(err, context.Canceled) {
		log.Fatalf("server stopped: %v", err)
	}
}

func runSrtpServer(ctx context.Context, listen, connect string, idleTimeout time.Duration, maxSessions int, m *metrics) error {
	addr, err := net.ResolveUDPAddr("udp", listen)
	if err != nil {
		return fmt.Errorf("resolve listen: %w", err)
	}
	srv, err := srtpwrap.Listen(addr)
	if err != nil {
		return err
	}
	defer srv.Close()

	context.AfterFunc(ctx, func() {
		_ = srv.Close()
	})

	log.Printf("vk-turn-proxy-server: listening on %s (srtp) -> %s", srv.Addr(), connect)

	var wg sync.WaitGroup
	defer wg.Wait()
	for {
		conn, err := srv.Accept(ctx)
		if err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, net.ErrClosed) || errors.Is(err, io.EOF) {
				return ctx.Err()
			}
			m.acceptErrors.Add(1)
			log.Printf("accept: %v", err)
			continue
		}
		if maxSessions > 0 && m.activeSessions.Load() >= int64(maxSessions) {
			m.rejectedSessions.Add(1)
			log.Printf("rejecting session from %s: max sessions reached (%d)", conn.RemoteAddr(), maxSessions)
			_ = conn.Close()
			continue
		}
		m.acceptedSessions.Add(1)
		m.activeSessions.Add(1)
		m.lastActivityUnix.Store(time.Now().Unix())
		wg.Add(1)
		go func() {
			defer wg.Done()
			handleSrtpSession(ctx, conn, connect, idleTimeout, m)
		}()
	}
}

func handleSrtpSession(ctx context.Context, conn net.Conn, connect string, idleTimeout time.Duration, m *metrics) {
	remote := conn.RemoteAddr().String()
	defer func() {
		_ = conn.Close()
		m.activeSessions.Add(-1)
		m.closedSessions.Add(1)
		log.Printf("session closed: %s", remote)
	}()

	backend, err := net.Dial("udp", connect)
	if err != nil {
		m.backendErrors.Add(1)
		log.Printf("[%s] backend dial: %v", remote, err)
		return
	}
	defer backend.Close()

	log.Printf("session from %s", remote)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stopDeadlineBreak := context.AfterFunc(ctx, func() {
		now := time.Now()
		_ = conn.SetDeadline(now)
		_ = backend.SetDeadline(now)
	})
	defer stopDeadlineBreak()

	var wg sync.WaitGroup
	wg.Add(2)
	go pipeClientToBackend(ctx, conn, backend, idleTimeout, remote, m, cancel)
	go pipeBackendToClient(ctx, backend, conn, idleTimeout, remote, m, cancel)
	wg.Wait()
}

func pipeClientToBackend(ctx context.Context, client net.Conn, backend net.Conn, idleTimeout time.Duration, remote string, m *metrics, cancel context.CancelFunc) {
	defer cancel()
	buf := make([]byte, 2048)
	for {
		if err := client.SetReadDeadline(time.Now().Add(idleTimeout)); err != nil {
			log.Printf("[%s] client deadline: %v", remote, err)
			return
		}
		n, err := client.Read(buf)
		if err != nil {
			logReadError(remote, "client", err)
			return
		}
		if n == 0 {
			continue
		}
		m.lastActivityUnix.Store(time.Now().Unix())
		if isProbePacket(buf[:n]) {
			if err := client.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil {
				log.Printf("[%s] probe deadline: %v", remote, err)
				return
			}
			if _, err := client.Write(buf[:n]); err != nil {
				log.Printf("[%s] probe echo: %v", remote, err)
				return
			}
			m.probeEchoes.Add(1)
			continue
		}
		if err := backend.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil {
			log.Printf("[%s] backend write deadline: %v", remote, err)
			return
		}
		if _, err := backend.Write(buf[:n]); err != nil {
			m.backendErrors.Add(1)
			log.Printf("[%s] backend write: %v", remote, err)
			return
		}
		m.rxBytes.Add(int64(n))
		select {
		case <-ctx.Done():
			return
		default:
		}
	}
}

func pipeBackendToClient(ctx context.Context, backend net.Conn, client net.Conn, idleTimeout time.Duration, remote string, m *metrics, cancel context.CancelFunc) {
	defer cancel()
	buf := make([]byte, 2048)
	for {
		if err := backend.SetReadDeadline(time.Now().Add(idleTimeout)); err != nil {
			log.Printf("[%s] backend deadline: %v", remote, err)
			return
		}
		n, err := backend.Read(buf)
		if err != nil {
			logReadError(remote, "backend", err)
			return
		}
		if n == 0 {
			continue
		}
		m.lastActivityUnix.Store(time.Now().Unix())
		if err := client.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil {
			log.Printf("[%s] client write deadline: %v", remote, err)
			return
		}
		if _, err := client.Write(buf[:n]); err != nil {
			log.Printf("[%s] client write: %v", remote, err)
			return
		}
		m.txBytes.Add(int64(n))
		select {
		case <-ctx.Done():
			return
		default:
		}
	}
}

func logReadError(remote, side string, err error) {
	if errors.Is(err, net.ErrClosed) || errors.Is(err, io.EOF) {
		return
	}
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		log.Printf("[%s] %s read idle timeout", remote, side)
		return
	}
	log.Printf("[%s] %s read: %v", remote, side, err)
}

func isProbePacket(buf []byte) bool {
	if len(buf) < len(probePingMagic) {
		return false
	}
	for i, b := range probePingMagic {
		if buf[i] != b {
			return false
		}
	}
	return true
}

func startHealthServer(ctx context.Context, listen, connect string, m *metrics) error {
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		return fmt.Errorf("admin health listen %s: %w", listen, err)
	}
	startHealthServerOnListener(ctx, ln, connect, m)
	return nil
}

func startHealthServerOnListener(ctx context.Context, ln net.Listener, connect string, m *metrics) {
	server := &http.Server{Handler: newHealthMux(connect, m)}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	go func() {
		log.Printf("admin health server listening on %s", ln.Addr())
		if err := server.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("admin health server: %v", err)
		}
	}()
}

func newHealthMux(connect string, m *metrics) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, "ok\n")
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		c, err := net.DialTimeout("udp", connect, 2*time.Second)
		if err != nil {
			http.Error(w, "backend dial failed: "+err.Error(), http.StatusServiceUnavailable)
			return
		}
		_ = c.Close()
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, "ready\n")
	})
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		writeMetric(w, "vk_turn_proxy_uptime_seconds", time.Now().Unix()-m.startedAtUnix)
		writeMetric(w, "vk_turn_proxy_active_sessions", m.activeSessions.Load())
		writeMetric(w, "vk_turn_proxy_accepted_sessions_total", m.acceptedSessions.Load())
		writeMetric(w, "vk_turn_proxy_rejected_sessions_total", m.rejectedSessions.Load())
		writeMetric(w, "vk_turn_proxy_closed_sessions_total", m.closedSessions.Load())
		writeMetric(w, "vk_turn_proxy_accept_errors_total", m.acceptErrors.Load())
		writeMetric(w, "vk_turn_proxy_backend_errors_total", m.backendErrors.Load())
		writeMetric(w, "vk_turn_proxy_probe_echoes_total", m.probeEchoes.Load())
		writeMetric(w, "vk_turn_proxy_rx_bytes_total", m.rxBytes.Load())
		writeMetric(w, "vk_turn_proxy_tx_bytes_total", m.txBytes.Load())
		writeMetric(w, "vk_turn_proxy_last_activity_unix", m.lastActivityUnix.Load())
	})
	return mux
}

func writeMetric(w io.Writer, name string, value int64) {
	_, _ = io.WriteString(w, name)
	_, _ = io.WriteString(w, " ")
	_, _ = io.WriteString(w, strconv.FormatInt(value, 10))
	_, _ = io.WriteString(w, "\n")
}
