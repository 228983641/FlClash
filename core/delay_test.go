package core

import (
	"fmt"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
)

func TestHandleTestDelaysMeasuresEveryKnownProxy(t *testing.T) {
	server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	withProbeProxies(t, "a", "b")

	results := handleTestDelays(&TestDelaysParams{
		Proxies: []string{"a", "b", "a"},
		TestUrl: server.URL,
		Timeout: 5000,
	})

	if len(results) != 2 {
		t.Fatalf("results = %v, want one entry per distinct proxy", results)
	}
	for _, name := range []string{"a", "b"} {
		if results[name] <= 0 {
			t.Errorf("results[%q] = %d, want a positive delay", name, results[name])
		}
	}
}

func TestHandleTestDelaysReportsAnUnknownProxyWithoutFailingTheBatch(t *testing.T) {
	server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	withProbeProxies(t, "a")

	results := handleTestDelays(&TestDelaysParams{
		Proxies: []string{"a", "missing"},
		TestUrl: server.URL,
		Timeout: 5000,
	})

	if results["a"] <= 0 {
		t.Errorf("results[%q] = %d, want a positive delay", "a", results["a"])
	}
	if results["missing"] != delayFailed {
		t.Errorf("results[%q] = %d, want %d", "missing", results["missing"], delayFailed)
	}
}

func TestHandleTestDelaysOmitsNodesThatNeverGotASlot(t *testing.T) {
	for i := 0; i < delayTestConcurrency; i++ {
		delayTestSlots <- struct{}{}
	}
	t.Cleanup(func() {
		for i := 0; i < delayTestConcurrency; i++ {
			<-delayTestSlots
		}
	})
	withProbeProxies(t, "queued")

	results := handleTestDelays(&TestDelaysParams{
		Proxies: []string{"queued", "missing"},
		TestUrl: "http://127.0.0.1:1",
		Timeout: 1,
	})

	if _, measured := results["queued"]; measured {
		t.Errorf("results = %v, want the slot-starved node omitted", results)
	}
	if results["missing"] != delayFailed {
		t.Errorf("results[%q] = %d, want %d", "missing", results["missing"], delayFailed)
	}
}

func TestHandleTestDelaysRunsTheBatchConcurrently(t *testing.T) {
	addr := blackHoleServer(t)
	names := make([]string, 8)
	for i := range names {
		names[i] = fmt.Sprintf("node-%d", i)
	}
	withProbeProxies(t, names...)

	start := time.Now()
	results := handleTestDelays(&TestDelaysParams{
		Proxies: names,
		TestUrl: "http://" + addr.String(),
		Timeout: 300,
	})
	elapsed := time.Since(start)

	for _, name := range names {
		if results[name] != delayTimedOut {
			t.Errorf("results[%q] = %d, want %d", name, results[name], delayTimedOut)
		}
	}
	// Sequentially the eight 300 ms probes would take at least 2.4 s.
	if elapsed > 1200*time.Millisecond {
		t.Errorf("batch took %v, want the probes to overlap", elapsed)
	}
}

func TestHandleTestDelaysSingleIssuesOneRequest(t *testing.T) {
	var requests atomic.Int32
	server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusNoContent)
	})
	withProbeProxies(t, "a")

	// Unified delay is what makes the standard test issue a second request.
	adapter.UnifiedDelay.Store(true)
	t.Cleanup(func() { adapter.UnifiedDelay.Store(false) })

	results := handleTestDelays(&TestDelaysParams{
		Proxies: []string{"a"},
		TestUrl: server.URL,
		Timeout: 5000,
	})
	if results["a"] <= 0 {
		t.Fatalf("standard results = %v, want a positive delay", results)
	}
	if got := requests.Load(); got != 2 {
		t.Fatalf("standard test issued %d requests, want 2 under unified delay", got)
	}

	requests.Store(0)
	results = handleTestDelays(&TestDelaysParams{
		Proxies: []string{"a"},
		TestUrl: server.URL,
		Timeout: 5000,
		Single:  true,
	})
	if results["a"] <= 0 {
		t.Fatalf("single results = %v, want a positive delay", results)
	}
	if got := requests.Load(); got != 1 {
		t.Errorf("single test issued %d requests, want 1", got)
	}
}

func TestHandleTestDelaysSingleTimesOutLikeTheStandardTest(t *testing.T) {
	addr := blackHoleServer(t)
	withProbeProxies(t, "a")

	results := handleTestDelays(&TestDelaysParams{
		Proxies: []string{"a"},
		TestUrl: "http://" + addr.String(),
		Timeout: 200,
		Single:  true,
	})

	if results["a"] != delayTimedOut {
		t.Errorf("results[%q] = %d, want %d", "a", results["a"], delayTimedOut)
	}
}
