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
