package core

import (
	"slices"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func closeGroupConnections(groups []string) {
	if len(groups) == 0 {
		return
	}
	closed := 0
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		for _, group := range groups {
			if slices.Contains(c.Info().Chain, group) {
				_ = c.Close()
				closed++
				break
			}
		}
		return true
	})
	log.Infoln("[SA] guarded-connections groups=%d closed=%d", len(groups), closed)
}

func groupSelections(groups []string) map[string]string {
	selectMu.Lock()
	defer selectMu.Unlock()
	selections := make(map[string]string, len(groups))
	for _, name := range groups {
		selections[name] = ""
		if selector, err := selectableGroup(name); err == nil {
			selections[name] = selector.Now()
		}
	}
	return selections
}

func closeChangedGroupConnections(before map[string]string) {
	groups := make([]string, 0, len(before))
	for name := range before {
		groups = append(groups, name)
	}
	after := groupSelections(groups)
	changed := groups[:0]
	for name, current := range after {
		if current != before[name] || current == "" || current == "REJECT" || current == "REJECT-DROP" {
			changed = append(changed, name)
		}
	}
	closeGroupConnections(changed)
}

func handleGetTraffic(onlyStatisticsProxy bool) Traffic {
	up, down := statistic.DefaultManager.NowTraffic(onlyStatisticsProxy)
	return Traffic{Up: up, Down: down}
}

func handleGetTotalTraffic(onlyStatisticsProxy bool) Traffic {
	up, down := statistic.DefaultManager.TotalTraffic(onlyStatisticsProxy)
	return Traffic{Up: up, Down: down}
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

func handleGetConnections() *statistic.Snapshot {
	return statistic.DefaultManager.Snapshot()
}

func handleGetConnectionCount() int {
	count := 0
	statistic.DefaultManager.Range(func(statistic.Tracker) bool {
		count++
		return true
	})
	return count
}

func handleCloseConnections() bool {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
	return true
}

func handleResetConnections() bool {
	resolver.ResetConnection()
	return true
}

// A network change clears rather than waits out the TTLs: mihomo serves an
// expired entry once more before it refreshes it.
func handleClearDnsCache() {
	configMu.Lock()
	defer configMu.Unlock()
	dns.ClearAll()
}

// A connection that went out over a network the device has left hangs until
// TCP gives up on it, and so do the DNS clients' pooled connections.
func handleResetNetwork() {
	handleCloseConnections()
	handleClearDnsCache()
}

func handleCloseConnection(connectionId string) bool {
	c := statistic.DefaultManager.Get(connectionId)
	if c == nil {
		return false
	}
	_ = c.Close()
	return true
}
