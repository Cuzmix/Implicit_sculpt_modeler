#+build js
package quadmesh

import "core:math"

// The web version has no C library (libm.odin) and no C++ core to match, so Odin's own.

@(private)
libm_pow :: proc(x, y: f64) -> f64 {
	return math.pow(x, y)
}

@(private)
libm_log :: proc(x: f64) -> f64 {
	return math.ln(x)
}
