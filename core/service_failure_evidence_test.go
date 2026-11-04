package core

import (
	"net/http"
	"testing"
)

func TestServiceCheckPreservesTransientHttpEvidence(t *testing.T) {
	withProbeProxies(t, "node-a")
	for _, code := range []int{429, 500, 502, 503} {
		t.Run(http.StatusText(code), func(t *testing.T) {
			server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(code)
			})
			withServiceCheckers(t, serviceChecker{name: "claude", check: checkReachable(server.URL)})
			items := handleServiceCheck(&ServiceCheckParams{ProxyName: "node-a", Names: []string{"claude"}, Timeout: 1000})
			if len(items) != 1 || items[0].FailureKind != "service" || items[0].Status != serviceUnavailable {
				t.Fatalf("HTTP %d = %+v, want transient service evidence", code, items)
			}
		})
	}
}

func TestServiceCheckDoesNotBlameNodesForMalformedPages(t *testing.T) {
	withServiceCheckers(t, stubChecker("claude", ServiceCheckItem{Status: serviceFailed}))
	item := handleServiceCheck(&ServiceCheckParams{Names: []string{"claude"}, Timeout: 1000})[0]
	if item.FailureKind != "unknown" {
		t.Fatalf("malformed response = %+v, want unknown evidence", item)
	}
}

func TestServiceCheckPreservesTransportEvidence(t *testing.T) {
	withProbeProxies(t, "node-a")
	server := probeServer(t, func(http.ResponseWriter, *http.Request) {})
	server.Close()
	withServiceCheckers(t, serviceChecker{name: "claude", check: checkReachable(server.URL)})
	item := handleServiceCheck(&ServiceCheckParams{ProxyName: "node-a", Names: []string{"claude"}, Timeout: 1000})[0]
	if item.FailureKind != "network" {
		t.Fatalf("closed server = %+v, want transport evidence", item)
	}
}
