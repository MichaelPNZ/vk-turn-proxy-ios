package proxy

import (
	"strings"
	"testing"
)

func TestSummarizeGoroutineStacks(t *testing.T) {
	dump := `goroutine 1 [running]:
github.com/cacggghp/vk-turn-proxy/pkg/proxy.captureGoroutineSummary()
	/Users/example/proxy.go:1848 +0x48

goroutine 2 [IO wait]:
github.com/pion/turn/v5.(*Client).readLoop()
	/Users/example/client.go:120 +0x88

goroutine 3 [IO wait]:
github.com/pion/turn/v5.(*Client).readLoop()
	/Users/example/client.go:120 +0x88

goroutine 4 [select]:
github.com/cacggghp/vk-turn-proxy/pkg/proxy.(*Proxy).growCredPool()
	/Users/example/creds.go:1400 +0x44
`

	got := summarizeGoroutineStacks(dump, 8)
	wantParts := []string{
		"goroutine-summary total=4",
		"states=IO wait:2,running:1,select:1",
		"github.com/pion/turn/v5.(*Client).readLoop:2",
		"github.com/cacggghp/vk-turn-proxy/pkg/proxy.(*Proxy).growCredPool:1",
	}
	for _, want := range wantParts {
		if !strings.Contains(got, want) {
			t.Fatalf("summary %q does not contain %q", got, want)
		}
	}
}

func TestSummarizeGoroutineStacksEmpty(t *testing.T) {
	got := summarizeGoroutineStacks("", 8)
	if got != "goroutine-summary total=0 states=none top=none" {
		t.Fatalf("empty summary = %q", got)
	}
}
