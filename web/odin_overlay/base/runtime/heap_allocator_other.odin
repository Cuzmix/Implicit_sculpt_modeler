#+build js, wasi, freestanding
#+private
package runtime

// The web build's stand-in for Odin's own base/runtime/heap_allocator_other.odin, which
// scripts/web_build.py puts in its place in an Odin root under build/web (deps/odin itself
// is never edited). Odin leaves runtime.heap_allocator unimplemented on js, while the
// sculpt engine allocates with it wherever work may run on a job (AGENTS.md); on js it
// takes its memory from the wasm allocator, Odin's default there, which grows the
// module's memory as it needs. Every other target keeps Odin's original: it panics.

_heap_alloc :: proc "contextless" (size: int, zero_memory := true) -> rawptr {
	context = default_context()
	when ODIN_OS == .JS {
		bytes, err := wasm_allocator_proc(nil, .Alloc if zero_memory else .Alloc_Non_Zeroed, size, 2 * align_of(rawptr), nil, 0)
		return raw_data(bytes) if err == nil else nil
	} else {
		unimplemented("base:runtime 'heap_alloc' procedure is not supported on this platform")
	}
}

_heap_resize :: proc "contextless" (ptr: rawptr, new_size: int) -> rawptr {
	context = default_context()
	when ODIN_OS == .JS {
		// realloc's terms: the new tail is not zeroed here; heap_allocator_proc zeroes it
		// when its caller asked for that.
		bytes, err := wasm_allocator_proc(nil, .Resize_Non_Zeroed, new_size, 2 * align_of(rawptr), ptr, 0)
		return raw_data(bytes) if err == nil else nil
	} else {
		unimplemented("base:runtime 'heap_resize' procedure is not supported on this platform")
	}
}

_heap_free :: proc "contextless" (ptr: rawptr) {
	context = default_context()
	when ODIN_OS == .JS {
		_, _ = wasm_allocator_proc(nil, .Free, 0, 0, ptr, 0)
	} else {
		unimplemented("base:runtime 'heap_free' procedure is not supported on this platform")
	}
}
