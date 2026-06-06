package main

import (
	"bytes"
	"testing"
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
