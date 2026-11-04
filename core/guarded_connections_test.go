package core

import (
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func TestGuardedApplyConfigRetiresExistingSocket(t *testing.T) {
	home := os.Getenv("FLCLASH_GUARDED_TEST_HOME")
	if home == "" {
		cmd := exec.Command(os.Args[0], "-test.run=^TestGuardedApplyConfigRetiresExistingSocket$")
		cmd.Env = append(os.Environ(), "FLCLASH_GUARDED_TEST_HOME="+t.TempDir())
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("isolated config apply: %v\n%s", err, output)
		}
		return
	}
	previousHome := constant.Path.HomeDir()
	constant.SetHomeDir(home)
	t.Cleanup(func() { constant.SetHomeDir(previousHome) })
	withCurrentConfig(t, nil)
	tunnel.UpdateProxies(map[string]constant.Proxy{"guarded": selectorGroup(t, "guarded", "old")}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
	_, remote := trackedGroupPipe(t, "guarded")
	profile := "profile:\n  store-selected: false\nproxy-groups:\n  - name: guarded\n    type: select\n    proxies: [REJECT]\nrules:\n  - MATCH,REJECT\n"
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), []byte(profile), 0600); err != nil {
		t.Fatal(err)
	}
	params := defaultSetupParams()
	params.GuardedGroups = []string{"guarded"}
	params.SelectedMap = map[string]string{"guarded": "REJECT"}
	if err := applyConfig(params); err != nil {
		t.Fatal(err)
	}
	assertPipeClosed(t, remote)
}

func trackedGroupPipe(t *testing.T, group string) (statistic.Tracker, net.Conn) {
	t.Helper()
	local, remote := net.Pipe()
	conn := outbound.NewConn(local, outbound.NewDirectWithOption(outbound.DirectOption{Name: "old-exit"}))
	conn.AppendToChains(outbound.NewDirectWithOption(outbound.DirectOption{Name: group}))
	tracker := statistic.NewTCPTracker(conn, statistic.DefaultManager, &constant.Metadata{}, nil, 0, 0, true)
	t.Cleanup(func() { _ = tracker.Close(); _ = remote.Close() })
	return tracker, remote
}

func assertPipeClosed(t *testing.T, remote net.Conn) {
	t.Helper()
	_ = remote.SetReadDeadline(time.Now().Add(time.Second))
	_, err := remote.Read(make([]byte, 1))
	if err != io.EOF {
		t.Fatalf("old socket read = %v, want EOF", err)
	}
}

func TestGuardedProxySwitchClosesBeforeAcknowledgement(t *testing.T) {
	for _, target := range []string{"new", "old"} {
		t.Run(target, func(t *testing.T) {
			group := selectorGroup(t, "guarded", "old", "new")
			tunnel.UpdateProxies(map[string]constant.Proxy{"guarded": group}, nil)
			t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
			old, remote := trackedGroupPipe(t, "guarded")
			other, _ := trackedGroupPipe(t, "unrelated")
			var params ChangeProxyParams
			if err := json.Unmarshal([]byte(`{"group-name":"guarded","proxy-name":"`+target+`","close-connections":true}`), &params); err != nil {
				t.Fatal(err)
			}
			result := handleChangeProxy(&params)
			if result.Message != "" {
				t.Fatal(result.Message)
			}
			if statistic.DefaultManager.Get(old.ID()) != nil {
				t.Fatal("acknowledged while old connection survived")
			}
			assertPipeClosed(t, remote)
			if statistic.DefaultManager.Get(other.ID()) == nil {
				t.Fatal("closed unrelated service")
			}
		})
	}
}

func TestRejectedGuardedSwitchKeepsConnections(t *testing.T) {
	tunnel.UpdateProxies(map[string]constant.Proxy{"guarded": selectorGroup(t, "guarded", "old")}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
	old, _ := trackedGroupPipe(t, "guarded")
	var params ChangeProxyParams
	_ = json.Unmarshal([]byte(`{"group-name":"guarded","proxy-name":"missing","close-connections":true}`), &params)
	if handleChangeProxy(&params).Message == "" {
		t.Fatal("accepted missing target")
	}
	if statistic.DefaultManager.Get(old.ID()) == nil {
		t.Fatal("closed connection after refused switch")
	}
}

func TestGuardedConfigSelectionClosesChangedRejectedAndRemovedGroups(t *testing.T) {
	for _, target := range []string{"new", "REJECT", ""} {
		t.Run(target, func(t *testing.T) {
			tunnel.UpdateProxies(map[string]constant.Proxy{"guarded": selectorGroup(t, "guarded", "old", "new", "REJECT")}, nil)
			t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
			before := groupSelections([]string{"guarded"})
			old, remote := trackedGroupPipe(t, "guarded")
			other, _ := trackedGroupPipe(t, "unrelated")
			if target == "" {
				tunnel.UpdateProxies(nil, nil)
			} else {
				patchSelectGroup(map[string]string{"guarded": target})
			}
			closeChangedGroupConnections(before)
			assertPipeClosed(t, remote)
			if statistic.DefaultManager.Get(old.ID()) != nil {
				t.Fatal("old tracker survived")
			}
			if statistic.DefaultManager.Get(other.ID()) == nil {
				t.Fatal("unrelated tracker closed")
			}
		})
	}
}

func TestGuardedConfigKeepsUnchangedHealthyGroup(t *testing.T) {
	tunnel.UpdateProxies(map[string]constant.Proxy{"guarded": selectorGroup(t, "guarded", "old")}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
	old, _ := trackedGroupPipe(t, "guarded")
	closeChangedGroupConnections(groupSelections([]string{"guarded"}))
	if statistic.DefaultManager.Get(old.ID()) == nil {
		t.Fatal("metadata refresh closed healthy route")
	}
}

func TestGuardedConfigReassertsReject(t *testing.T) {
	tunnel.UpdateProxies(map[string]constant.Proxy{"guarded": selectorGroup(t, "guarded", "REJECT")}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
	_, remote := trackedGroupPipe(t, "guarded")
	closeChangedGroupConnections(groupSelections([]string{"guarded"}))
	assertPipeClosed(t, remote)
}
