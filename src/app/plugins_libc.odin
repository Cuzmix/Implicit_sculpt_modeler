#+build !js
package main

import "core:c"
import "core:c/libc"

// The C allocator Luau's compiler and VMs use (plugins.odin), kept apart because core:c/libc
// does not build for the web version, which has no plugins (luau.AVAILABLE).

plugin_c_free :: proc "c" (ptr: rawptr) {
	libc.free(ptr)
}

plugin_c_realloc :: proc "c" (ptr: rawptr, size: c.size_t) -> rawptr {
	return libc.realloc(ptr, size)
}
