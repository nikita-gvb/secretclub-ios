// SecretClub: добавляется в пакет xray libXray (scripts/build-libxray.sh).
// Счётчики статистики работающего ядра напрямую, без API- или metrics-сервера.
package xray

import (
	"errors"

	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/features/stats"
)

// CounterValue возвращает значение счётчика (например, "inbound>>>tun>>>traffic>>>downlink").
// ok=false — ядро не запущено или такого счётчика нет.
func CounterValue(name string) (value int64, ok bool) {
	coreServerMu.Lock()
	defer coreServerMu.Unlock()
	if coreServer == nil {
		return 0, false
	}
	manager, isManager := coreServer.GetFeature(stats.ManagerType()).(stats.Manager)
	if !isManager || manager == nil {
		return 0, false
	}
	counter := manager.GetCounter(name)
	if counter == nil {
		return 0, false
	}
	return counter.Value(), true
}

// SetBalancerTarget направляет балансировщик на outbound target (BalancerOverrider роутера Xray).
// Так рабочий сервер меняется без перезапуска ядра: все запасные уже загружены в него.
func SetBalancerTarget(balancer, target string) error {
	coreServerMu.Lock()
	defer coreServerMu.Unlock()
	if coreServer == nil {
		return errors.New("core is not running")
	}
	overrider, ok := coreServer.GetFeature(routing.RouterType()).(routing.BalancerOverrider)
	if !ok || overrider == nil {
		return errors.New("router cannot override balancer")
	}
	return overrider.SetOverrideTarget(balancer, target)
}
