package bench

import "base:runtime"
import "core:sync"

// Counts what goes through an allocator and passes every call on to the one it wraps.
// main wraps the context's heap and temp allocators before anything is made, so the
// sculptors keep the counting ones, and a stroke's allocations are the difference of
// two readings. Worker jobs allocate with runtime.heap_allocator() (AGENTS.md), which
// this does not see; the counts are what the calling thread asked for.
Alloc_Count :: struct {
	backing: runtime.Allocator,
	calls:   u64, // allocations and resizes
	bytes:   u64, // bytes they asked for
}

alloc_count_allocator :: proc(c: ^Alloc_Count) -> runtime.Allocator {
	return {procedure = alloc_count_proc, data = c}
}

@(private = "file")
alloc_count_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	c := cast(^Alloc_Count)data
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		sync.atomic_add(&c.calls, 1)
		sync.atomic_add(&c.bytes, u64(max(size, 0)))
	}
	return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// The heap and temp counters main installs.
heap_count, temp_count: Alloc_Count

// A reading of both counters, to subtract from a later one.
Alloc_Reading :: struct {
	heap_calls, heap_bytes, temp_calls, temp_bytes: u64,
}

alloc_read :: proc() -> Alloc_Reading {
	return {
		sync.atomic_load(&heap_count.calls),
		sync.atomic_load(&heap_count.bytes),
		sync.atomic_load(&temp_count.calls),
		sync.atomic_load(&temp_count.bytes),
	}
}

alloc_since :: proc(from: Alloc_Reading) -> Alloc_Reading {
	now := alloc_read()
	return {now.heap_calls - from.heap_calls, now.heap_bytes - from.heap_bytes, now.temp_calls - from.temp_calls, now.temp_bytes - from.temp_bytes}
}
