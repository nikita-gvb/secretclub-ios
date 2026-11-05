//go:build ios

// SecretClub: замена memory/memory_ios.go из libXray.
// В оригинале горутина вызывает debug.FreeOSMemory() каждую секунду, пока жив процесс,
// и GOGC=10 — процессор просыпается постоянно, даже когда трафика нет (батарея).
// Здесь: раз в 10 с смотрим, сколько памяти удерживает рантайм, и отдаём её системе,
// только если много. Жёсткий предел 30 МБ (у расширения iOS лимит 50 МБ) остаётся.
package memory

import (
	"runtime/debug"
	"runtime/metrics"
	"sync"
	"time"
)

const (
	gcPercent     = 30
	maxMemory     = 30 * 1024 * 1024
	freeAbove     = 20 * 1024 * 1024
	checkInterval = 10 * time.Second
)

var initForceFreeOnce sync.Once

// retained — сколько памяти рантайм Go держит у системы (без уже возвращённой).
func retained() uint64 {
	samples := []metrics.Sample{
		{Name: "/memory/classes/total:bytes"},
		{Name: "/memory/classes/heap/released:bytes"},
	}
	metrics.Read(samples)
	if samples[0].Value.Kind() != metrics.KindUint64 || samples[1].Value.Kind() != metrics.KindUint64 {
		return 0
	}
	total, released := samples[0].Value.Uint64(), samples[1].Value.Uint64()
	if released > total {
		return 0
	}
	return total - released
}

func watch() {
	go func() {
		ticker := time.NewTicker(checkInterval)
		defer ticker.Stop()
		for range ticker.C {
			if retained() > freeAbove {
				debug.FreeOSMemory()
			}
		}
	}()
}

func InitForceFree() {
	initForceFreeOnce.Do(func() {
		debug.SetGCPercent(gcPercent)
		debug.SetMemoryLimit(maxMemory)
		watch()
	})
}
