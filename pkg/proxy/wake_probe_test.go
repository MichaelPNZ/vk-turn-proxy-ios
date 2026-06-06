package proxy

import "testing"

func TestWakeProbeLimitForNumConns(t *testing.T) {
	tests := []struct {
		numConns int
		want     int
	}{
		{numConns: -1, want: 1},
		{numConns: 0, want: 1},
		{numConns: 1, want: 1},
		{numConns: 10, want: 1},
		{numConns: 11, want: 2},
		{numConns: 30, want: 3},
		{numConns: 50, want: 5},
		{numConns: 70, want: 6},
		{numConns: 120, want: 6},
	}

	for _, tt := range tests {
		if got := wakeProbeLimitForNumConns(tt.numConns); got != tt.want {
			t.Fatalf("wakeProbeLimitForNumConns(%d) = %d, want %d", tt.numConns, got, tt.want)
		}
	}
}

func TestWakeProbeSlotSemaphore(t *testing.T) {
	p := &Proxy{wakeProbeSlots: make(chan struct{}, 2)}

	if !p.tryAcquireWakeProbeSlot() {
		t.Fatal("first acquire failed")
	}
	if !p.tryAcquireWakeProbeSlot() {
		t.Fatal("second acquire failed")
	}
	if p.tryAcquireWakeProbeSlot() {
		t.Fatal("third acquire succeeded despite full limiter")
	}

	p.releaseWakeProbeSlot()
	if !p.tryAcquireWakeProbeSlot() {
		t.Fatal("acquire after release failed")
	}
}
