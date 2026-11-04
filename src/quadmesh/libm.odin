#+build !js
package quadmesh

import "core:c/libc"

// The C library's pow and log, which the C++ core's landing calls: the driver's bracket
// must give the C++'s scaling bit for bit, and Odin's own core:math rounds differently in
// the last place. Kept apart because core:c/libc does not build for the web version
// (libm_js.odin).

@(private)
libm_pow :: proc(x, y: f64) -> f64 {
	return libc.pow(x, y)
}

@(private)
libm_log :: proc(x: f64) -> f64 {
	return libc.log(x)
}
