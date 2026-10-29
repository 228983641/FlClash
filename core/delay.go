package core

import (
	"context"
	"net"
	"net/url"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/constant"
)

const (
	delayTestConcurrency    = 50
	defaultTestURL          = "https://www.gstatic.com/generate_204"
	defaultDelayTestTimeout = 5 * time.Second
)

var (
	delayTestSlots     = make(slots, delayTestConcurrency)
	anyDelayTestStatus utils.IntRanges[uint16]

	testURL                 atomic.Pointer[string]
	missingDelayTestProxyAt atomic.Int64
)

func setTestURL(url string) {
	if url == "" {
		return
	}
	constant.DefaultTestURL = url
	testURL.Store(&url)
}

func currentTestURL() string {
	if url := testURL.Load(); url != nil && *url != "" {
		return *url
	}
	return defaultTestURL
}

const (
	delayTimedOut int32 = -1
	delayFailed   int32 = -2
)

func delayValue(delay uint16, timedOut bool) int32 {
	switch {
	case delay > 0:
		return int32(delay)
	case timedOut:
		return delayTimedOut
	default:
		return delayFailed
	}
}

// A name the tunnel does not know is what an apply that fell back to the
// default config looks like: every node of the profile fails its test. Say so
// once a second, not once per node, so the log names the real failure.
func reportMissingDelayTestProxy(name string) {
	now := time.Now().UnixNano()
	last := missingDelayTestProxyAt.Load()
	if last != 0 && now-last < int64(time.Second) {
		return
	}
	if !missingDelayTestProxyAt.CompareAndSwap(last, now) {
		return
	}
	logError("delay test: %q is not part of the applied config", name)
}

// A nil answer means the test never got a slot, which says nothing about the proxy.
func handleTestDelay(params *TestDelayParams) *Delay {
	return testDelay(params, false)
}

const delayBatchConcurrency = 32

// handleTestDelays runs one batch inside the Core, bounded by
// delayBatchConcurrency workers, instead of one host call per node. A name
// missing from the result carries the single test's nil meaning: the node
// was never measured. Every measured name keeps the single test's value
// conventions, failures included.
func handleTestDelays(params *TestDelaysParams) map[string]int32 {
	results := make(map[string]int32, len(params.Proxies))
	var mu sync.Mutex
	jobs := make(chan string)
	var wg sync.WaitGroup
	for range delayBatchConcurrency {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for name := range jobs {
				delay := testDelay(&TestDelayParams{
					ProxyName: name,
					TestUrl:   params.TestUrl,
					Timeout:   params.Timeout,
				}, params.Single)
				if delay == nil {
					continue
				}
				mu.Lock()
				results[name] = delay.Value
				mu.Unlock()
			}
		}()
	}
	seen := make(map[string]bool, len(params.Proxies))
	for _, name := range params.Proxies {
		if seen[name] {
			continue
		}
		seen[name] = true
		jobs <- name
	}
	close(jobs)
	wg.Wait()
	return results
}

// With single set, the probe issues one request instead of the pair
// proxy.URLTest runs under unified delay; a screening pass over every node
// then costs half the requests, and only the precision of a delay no later
// pass refines is given up.
func testDelay(params *TestDelayParams, single bool) *Delay {
	url := params.TestUrl
	if url == "" {
		url = currentTestURL()
	}
	result := &Delay{Name: params.ProxyName, Url: url, Value: delayFailed}

	proxy := lookupProxy(params.ProxyName)
	if proxy == nil {
		reportMissingDelayTestProxy(params.ProxyName)
		return result
	}

	timeout := timeoutFromMillis(params.Timeout, defaultDelayTestTimeout)
	if !delayTestSlots.acquireWithin(context.Background(), timeout) {
		return nil
	}
	defer delayTestSlots.release()

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	var delay uint16
	var err error
	if single {
		delay, err = urlTestOnce(ctx, proxy, url)
	} else {
		delay, err = proxy.URLTest(ctx, url, anyDelayTestStatus)
	}
	if err != nil {
		delay = 0
	}
	result.Value = delayValue(delay, ctx.Err() != nil)
	return result
}

// urlTestOnce is proxy.URLTest limited to its first request: the second
// request URLTest issues under unified delay exists to exclude connection
// setup from the measurement, which a screening pass does not need. It
// reports the same delay convention, elapsed milliseconds with a floor of
// one on success.
func urlTestOnce(ctx context.Context, proxy constant.Proxy, rawURL string) (uint16, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return 0, err
	}
	port := parsed.Port()
	if port == "" {
		port = "80"
		if parsed.Scheme == "https" {
			port = "443"
		}
	}
	metadata, err := probeMetadata(net.JoinHostPort(parsed.Hostname(), port))
	if err != nil {
		return 0, err
	}
	tlsConfig, err := ca.GetTLSConfig(ca.Option{})
	if err != nil {
		return 0, err
	}

	start := time.Now()
	conn, err := proxy.DialContext(ctx, metadata)
	if err != nil {
		return 0, err
	}
	defer func() { _ = conn.Close() }()

	transport := &http.Transport{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return conn, nil
		},
		TLSClientConfig:     tlsConfig,
		TLSHandshakeTimeout: 10 * time.Second,
		MaxIdleConns:        1,
		IdleConnTimeout:     90 * time.Second,
	}
	defer transport.CloseIdleConnections()
	client := http.Client{
		Transport: transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodHead, rawURL, nil)
	if err != nil {
		return 0, err
	}
	response, err := client.Do(request)
	if err != nil {
		return 0, err
	}
	_ = response.Body.Close()

	delay := uint16(time.Since(start) / time.Millisecond)
	if delay == 0 {
		delay = 1
	}
	return delay, nil
}
