package core

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/http"
)

const (
	// A sweep runs a few checks at a time so it cannot take every probe slot.
	// It therefore runs in waves, and a rule like Disney+ spends several
	// requests in sequence, so the run gets a multiple of the request budget.
	serviceCheckConcurrency  = 4
	serviceSweepBudgetFactor = 6

	// Region markers sit deep inside these pages; endpoints that answer with a
	// few lines get the small cap.
	serviceHtmlMaxBody  = 512 * 1024
	serviceSmallMaxBody = 16 * 1024

	// Gemini's region sits past 800 KiB, Prime Video's at times past 4 MiB.
	serviceScanMaxBody = 8 * 1024 * 1024
)

// Statuses a check reports. Dart maps each to a localized label, so these
// strings are part of the contract and cannot be reworded on one side alone.
const (
	serviceAvailable         = "available"
	serviceUnavailable       = "unavailable"
	serviceRestricted        = "restricted"
	serviceDisallowedIsp     = "disallowed-isp"
	serviceBlocked           = "blocked"
	serviceUnsupportedRegion = "unsupported-region"
	serviceOriginalsOnly     = "originals-only"
	serviceComingSoon        = "coming-soon"
	serviceTimeout           = "timeout"
	serviceFailed            = "failed"
	serviceCancelled         = "cancelled"
)

// An empty Names runs every check.
type ServiceCheckParams struct {
	ProxyName string   `json:"proxy-name"`
	Names     []string `json:"names"`
	Timeout   int64    `json:"timeout"`
	// Scope names the host caller (the status panel or the smart-anchor
	// prober). Claims and slots are kept per scope, so one caller's checks
	// never cancel or starve the other's. Callers that send no scope share
	// the empty scope and the prober's slots.
	Scope string `json:"scope"`
}

// runServiceCheck stamps Name; a blank Status means a rule has yet to judge it.
type ServiceCheckItem struct {
	Name         string     `json:"name"`
	Status       string     `json:"status"`
	Region       string     `json:"region,omitempty"`
	Delay        int64      `json:"delay,omitempty"`
	Chains       []string   `json:"chains,omitempty"`
	CheckedAt    int64      `json:"checked-at"`
	CoreEpoch    uint64     `json:"core-epoch"`
	RouteVersion uint64     `json:"route-version"`
	Hits         []RouteHit `json:"hits,omitempty"`
}

// The panel scope value the host sends; every other scope shares the
// prober pool below.
const scopePanel = "panel"

var (
	// One slot pool per caller scope, so a panel sweep cannot starve the
	// prober and the prober cannot starve the panel. Each pool keeps the
	// old sweep bound; together they cap service checks at twice that.
	servicePanelCheckSlots = make(slots, serviceCheckConcurrency)
	serviceProbeCheckSlots = make(slots, serviceCheckConcurrency)

	serviceClaimsMu sync.Mutex
	serviceClaims   = map[string]*serviceClaim{}
)

type serviceClaim struct {
	cancel context.CancelCauseFunc
}

func slotsForScope(scope string) slots {
	if scope == scopePanel {
		return servicePanelCheckSlots
	}
	return serviceProbeCheckSlots
}

// A claim names one check of one route: the same service asked through a
// different proxy is a different question and must not cancel this one.
func claimKey(scope, name, proxyName string) string {
	return scope + "\x00" + name + "\x00" + proxyName
}

type serviceEnv struct {
	ctx       context.Context
	proxyName string
	timeout   time.Duration
	hits      *hitRecorder
}

func (e serviceEnv) get(url string, maxBody int64) *ProbeResult {
	return e.send(probeRequest{method: http.MethodGet, url: url, maxBody: maxBody})
}

func (e serviceEnv) scan(url string, until func(tail string) bool) *ProbeResult {
	return e.send(probeRequest{method: http.MethodGet, url: url, maxBody: serviceScanMaxBody, until: until})
}

func (e serviceEnv) send(req probeRequest) *ProbeResult {
	req.proxyName = e.proxyName
	req.timeout = e.timeout
	req.recorder = e.hits
	headers := map[string]string{"User-Agent": browserUserAgent}
	for name, value := range req.headers {
		headers[name] = value
	}
	req.headers = headers
	return runProbe(e.ctx, req)
}

type serviceChecker struct {
	name  string
	check func(serviceEnv) ServiceCheckItem
}

var serviceCheckers = []serviceChecker{
	{name: "google", check: checkReachable("https://www.google.com/generate_204")},
	{name: "github", check: checkReachable("https://github.com/")},
	{name: "youtube", check: checkYouTubePremium},
	{name: "chatgpt", check: checkChatGpt},
	{name: "claude", check: checkClaude},
	{name: "gemini", check: checkGemini},
	{name: "netflix", check: checkNetflix},
	{name: "disney-plus", check: checkDisneyPlus},
	{name: "prime-video", check: checkPrimeVideo},
	{name: "spotify", check: checkSpotify},
	{name: "tiktok", check: checkTikTok},
	{name: "discord", check: checkDiscord},
	{name: "bilibili", check: checkBilibili},
}

func handleServiceCheck(params *ServiceCheckParams) []ServiceCheckItem {
	wanted := selectedCheckers(params.Names)
	items := make([]ServiceCheckItem, len(wanted))
	if len(wanted) == 0 {
		return items
	}

	timeout := timeoutFromMillis(params.Timeout, defaultProbeTimeout)
	ctx, cancel := context.WithTimeout(context.Background(), timeout*serviceSweepBudgetFactor)
	defer cancel()

	// Claimed before queueing, so a check waiting for a slot is cancelled the
	// moment its service is asked again.
	contexts, release := claimServices(ctx, params.Scope, params.ProxyName, wanted)
	defer release()
	pool := slotsForScope(params.Scope)
	var running sync.WaitGroup
	for index, checker := range wanted {
		granted := pool.acquire(contexts[index])
		running.Add(1)
		go func(index int, checker serviceChecker) {
			defer running.Done()
			if granted {
				defer pool.release()
			}
			items[index] = runServiceCheck(contexts[index], checker, params.ProxyName, timeout)
		}(index, checker)
	}
	running.Wait()
	return items
}

// A misbehaving rule must not take the sweep down with it.
func runServiceCheck(ctx context.Context, checker serviceChecker, proxyName string, timeout time.Duration) (item ServiceCheckItem) {
	epoch, version := routeStamp()
	hits := &hitRecorder{}
	item = ServiceCheckItem{Status: serviceFailed}
	defer func() {
		if recovered := recover(); recovered != nil {
			item = ServiceCheckItem{Status: serviceFailed}
		}
		// A check replaced by a newer request from the same caller never
		// judged its node; report it as cancelled so the host does not
		// mistake the outcome for a node failure.
		if (item.Status == serviceFailed || item.Status == serviceTimeout) &&
			errors.Is(context.Cause(ctx), errServiceCheckReplaced) {
			item.Status = serviceCancelled
			item.Delay = 0
		}
		item.Name = checker.name
		item.CheckedAt = time.Now().UnixMilli()
		item.CoreEpoch = epoch
		item.RouteVersion = version
		item.Hits = hits.list()
	}()
	if ctx.Err() != nil {
		return item
	}
	env := serviceEnv{ctx: ctx, proxyName: proxyName, timeout: timeout, hits: hits}
	item = checker.check(env)
	if retryable(item) && ctx.Err() == nil && hasBudget(ctx, timeout) {
		item = checker.check(env)
	}
	return item
}

// retryable reports whether a check ended without an answer from a node: a
// timeout, or a failure with no route chain, as when the probe got no slot
// or the connection died before it settled. A failure a rule judged from a
// response carries its chain and stands as the answer.
func retryable(item ServiceCheckItem) bool {
	return item.Status == serviceTimeout ||
		(item.Status == serviceFailed && len(item.Chains) == 0)
}

// errServiceCheckReplaced is the cancellation cause of a check a newer
// request from the same caller scope superseded; runServiceCheck turns
// such an outcome into serviceCancelled.
var errServiceCheckReplaced = errors.New("service check replaced by a newer request")

// The host asks for a service again only once the older answer can no longer
// be used, so a newer check cancels the older one and frees its probe slots.
// Claims are keyed by caller scope and route as well as service: one
// caller asking again never cancels the other caller's check, nor a
// check of the same service through another proxy.
func claimServices(parent context.Context, scope, proxyName string, checkers []serviceChecker) ([]context.Context, func()) {
	contexts := make([]context.Context, len(checkers))
	claimed := make(map[string]context.Context, len(checkers))
	var releases []func()
	for index, checker := range checkers {
		ctx, ok := claimed[checker.name]
		if !ok {
			var release func()
			ctx, release = claimService(parent, claimKey(scope, checker.name, proxyName))
			claimed[checker.name] = ctx
			releases = append(releases, release)
		}
		contexts[index] = ctx
	}
	return contexts, func() {
		for _, release := range releases {
			release()
		}
	}
}

func claimService(parent context.Context, key string) (context.Context, func()) {
	ctx, cancel := context.WithCancelCause(parent)
	claim := &serviceClaim{cancel: cancel}
	serviceClaimsMu.Lock()
	if previous := serviceClaims[key]; previous != nil {
		previous.cancel(errServiceCheckReplaced)
	}
	serviceClaims[key] = claim
	serviceClaimsMu.Unlock()
	return ctx, func() {
		cancel(context.Canceled)
		serviceClaimsMu.Lock()
		if serviceClaims[key] == claim {
			delete(serviceClaims, key)
		}
		serviceClaimsMu.Unlock()
	}
}

func hasBudget(ctx context.Context, timeout time.Duration) bool {
	deadline, ok := ctx.Deadline()
	return !ok || time.Until(deadline) >= timeout
}

func selectedCheckers(names []string) []serviceChecker {
	if len(names) == 0 {
		return serviceCheckers
	}
	wanted := make([]serviceChecker, 0, len(names))
	for _, name := range names {
		for _, checker := range serviceCheckers {
			if checker.name == name {
				wanted = append(wanted, checker)
				break
			}
		}
	}
	return wanted
}

// checkReachable is the rule for a target with no unlock semantics of its own.
func checkReachable(url string) func(serviceEnv) ServiceCheckItem {
	return func(env serviceEnv) ServiceCheckItem {
		result := env.get(url, 0)
		item := itemFrom(result)
		if item.Status != "" {
			return item
		}
		item.Status = statusFromCode(result.StatusCode)
		return item
	}
}

func itemFrom(result *ProbeResult) ServiceCheckItem {
	if result == nil {
		return ServiceCheckItem{Status: serviceFailed}
	}
	item := ServiceCheckItem{Delay: result.Delay, Chains: result.Chains}
	switch result.Error {
	case "":
	case probeErrorTimeout:
		item.Status = serviceTimeout
		item.Delay = 0
	default:
		item.Status = serviceFailed
		item.Delay = 0
	}
	return item
}

func statusFromCode(code int) string {
	switch {
	case code >= 200 && code < 300:
		return serviceAvailable
	case code == http.StatusUnauthorized,
		code == http.StatusForbidden,
		code == http.StatusTooManyRequests,
		code == http.StatusUnavailableForLegalReasons:
		return serviceRestricted
	default:
		return serviceUnavailable
	}
}

func answered(item ServiceCheckItem, result *ProbeResult) bool {
	return item.Status == "" && result != nil
}

func bodyContains(result *ProbeResult, needles ...string) bool {
	if result.lowerBody == "" {
		result.lowerBody = strings.ToLower(result.Body)
	}
	for _, needle := range needles {
		if strings.Contains(result.lowerBody, needle) {
			return true
		}
	}
	return false
}

func traceValue(body string, key string) string {
	for _, line := range strings.Split(body, "\n") {
		if rest, found := strings.CutPrefix(line, key+"="); found {
			return strings.TrimSpace(rest)
		}
	}
	return ""
}
