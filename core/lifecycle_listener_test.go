package core

import (
	"net"
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/listener"
)

func TestStartListenerRetriesBindingAfterPortIsReleased(t *testing.T) {
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = occupied.Close() })
	port := occupied.Addr().(*net.TCPAddr).Port
	previousConfig, previousRunning := currentConfig, isRunning.Load()
	t.Cleanup(func() {
		handleStopListener()
		currentConfig = previousConfig
		isRunning.Store(previousRunning)
	})
	currentConfig = &config.Config{
		General: &config.General{Inbound: config.Inbound{MixedPort: port}},
	}
	isRunning.Store(false)

	ensureListenerBindings()
	if got := listener.GetPorts().MixedPort; got != 0 {
		t.Fatalf("occupied mixed port unexpectedly bound: %d", got)
	}
	if err := occupied.Close(); err != nil {
		t.Fatal(err)
	}

	ensureListenerBindings()
	if got := listener.GetPorts().MixedPort; got != port {
		t.Fatalf("second start bound port %d, want %d", got, port)
	}
	epoch := routeState().CoreEpoch
	ensureListenerBindings()
	if got := listener.GetPorts().MixedPort; got != port {
		t.Fatalf("repeated start lost mixed port: %d", got)
	}
	if got := routeState().CoreEpoch; got != epoch {
		t.Fatalf("listener reconciliation changed route epoch: %d, want %d", got, epoch)
	}
}
