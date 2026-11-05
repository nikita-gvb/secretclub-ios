// SecretClub: добавляется в cgo_bridge libXray (scripts/build-libxray.sh).
package main

import "C"

import "github.com/xtls/libxray/xray"

// SecretClubCounter — значение счётчика статистики ядра; -1, если ядра или счётчика нет.
//
//export SecretClubCounter
func SecretClubCounter(name *C.char) C.longlong {
	if name == nil {
		return -1
	}
	value, ok := xray.CounterValue(C.GoString(name))
	if !ok {
		return -1
	}
	return C.longlong(value)
}

// SecretClubSetBalancerTarget — переключить балансировщик на outbound; 1 — получилось, 0 — нет.
//
//export SecretClubSetBalancerTarget
func SecretClubSetBalancerTarget(balancer *C.char, target *C.char) C.int {
	if balancer == nil || target == nil {
		return 0
	}
	if err := xray.SetBalancerTarget(C.GoString(balancer), C.GoString(target)); err != nil {
		return 0
	}
	return 1
}
