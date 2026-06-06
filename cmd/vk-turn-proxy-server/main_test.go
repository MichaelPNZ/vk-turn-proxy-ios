package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestIsProbePacket(t *testing.T) {
	if !isProbePacket([]byte{0xff, 'P', 'N', 'G', 0x01}) {
		t.Fatal("expected probe packet")
	}
	if isProbePacket([]byte{0xff, 'P', 'N'}) {
		t.Fatal("short probe prefix should not match")
	}
	if isProbePacket([]byte{0xff, 'P', 'N', 'X'}) {
		t.Fatal("wrong probe magic should not match")
	}
}

func TestWriteMetric(t *testing.T) {
	var out bytes.Buffer
	writeMetric(&out, "vk_turn_proxy_rejected_sessions_total", 3)

	const want = "vk_turn_proxy_rejected_sessions_total 3\n"
	if got := out.String(); got != want {
		t.Fatalf("metric mismatch\ngot:  %q\nwant: %q", got, want)
	}
}

func TestHealthMuxEndpoints(t *testing.T) {
	m := &metrics{startedAtUnix: time.Now().Add(-10 * time.Second).Unix()}
	m.activeSessions.Store(2)
	m.acceptedSessions.Store(7)
	m.rejectedSessions.Store(1)
	m.closedSessions.Store(5)
	m.acceptErrors.Store(3)
	m.backendErrors.Store(4)
	m.probeEchoes.Store(6)
	m.rxBytes.Store(1024)
	m.txBytes.Store(2048)
	m.lastActivityUnix.Store(1234567890)

	server := httptest.NewServer(newHealthMux("127.0.0.1:51820", m))
	defer server.Close()

	assertTextEndpoint(t, server.URL+"/healthz", http.StatusOK, "ok\n")
	assertTextEndpoint(t, server.URL+"/readyz", http.StatusOK, "ready\n")

	resp, err := http.Get(server.URL + "/metrics")
	if err != nil {
		t.Fatalf("GET /metrics: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/metrics status=%d", resp.StatusCode)
	}
	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read /metrics: %v", err)
	}
	body := string(bodyBytes)
	for _, want := range []string{
		"vk_turn_proxy_active_sessions 2\n",
		"vk_turn_proxy_accepted_sessions_total 7\n",
		"vk_turn_proxy_rejected_sessions_total 1\n",
		"vk_turn_proxy_closed_sessions_total 5\n",
		"vk_turn_proxy_accept_errors_total 3\n",
		"vk_turn_proxy_backend_errors_total 4\n",
		"vk_turn_proxy_probe_echoes_total 6\n",
		"vk_turn_proxy_rx_bytes_total 1024\n",
		"vk_turn_proxy_tx_bytes_total 2048\n",
		"vk_turn_proxy_last_activity_unix 1234567890\n",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("/metrics missing %q in:\n%s", want, body)
		}
	}
}

func TestReadyzRejectsInvalidBackendAddress(t *testing.T) {
	m := &metrics{startedAtUnix: time.Now().Unix()}
	server := httptest.NewServer(newHealthMux("not a udp address", m))
	defer server.Close()

	resp, err := http.Get(server.URL + "/readyz")
	if err != nil {
		t.Fatalf("GET /readyz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("/readyz status=%d, want %d", resp.StatusCode, http.StatusServiceUnavailable)
	}
	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read /readyz: %v", err)
	}
	if !strings.Contains(string(bodyBytes), "backend dial failed:") {
		t.Fatalf("/readyz body missing backend error: %q", string(bodyBytes))
	}
}

func assertTextEndpoint(t *testing.T, url string, wantStatus int, wantBody string) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != wantStatus {
		t.Fatalf("%s status=%d, want %d", url, resp.StatusCode, wantStatus)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read %s: %v", url, err)
	}
	if string(body) != wantBody {
		t.Fatalf("%s body=%q, want %q", url, string(body), wantBody)
	}
}
