package gpu

import "core:sync"

// The resources render holds are generational handles into one pool per kind: the low
// HANDLE_SLOT_BITS of a handle are its slot plus one (so 0 is none), the rest the slot's
// generation when the handle was made. Releasing a resource bumps its slot's generation,
// so a handle kept past its release no longer resolves: the lookup answers nil instead of
// memory that was freed or now holds another object.
//
// Slots live in pages that never move once made, so a lookup reads without the lock; only
// making and releasing take it, as uploads and kernels are made on more than one thread.

HANDLE_SLOT_BITS :: 20
HANDLE_SLOTS_MAX :: 1 << HANDLE_SLOT_BITS - 1
@(private = "file")
POOL_PAGE :: 4096
@(private = "file")
POOL_PAGES :: (HANDLE_SLOTS_MAX + POOL_PAGE - 1) / POOL_PAGE

@(private = "file")
Pool_Slot :: struct {
	object:     rawptr,
	generation: u32,
}

@(private)
Pool :: struct {
	mutex: sync.Mutex,
	pages: [POOL_PAGES]^[POOL_PAGE]Pool_Slot,
	used:  int, // slots ever handed out; those below it not live are on `free`
	free:  [dynamic]u32,
	live:  int,
}

@(private)
Pools :: struct {
	buffers, transfer_buffers, textures, samplers, shaders, graphics_pipelines, compute_pipelines, readbacks: Pool,
}

@(private)
pools: Pools

@(private = "file")
pool_slot :: #force_inline proc "contextless" (p: ^Pool, slot: u32) -> ^Pool_Slot {
	page := p.pages[slot / POOL_PAGE]
	return &page[slot % POOL_PAGE] if page != nil else nil
}

// Puts `object` in a free slot and returns its handle; 0 for a nil object or a full pool.
@(private)
pool_add :: proc(p: ^Pool, object: rawptr) -> u32 {
	if object == nil do return 0
	sync.mutex_guard(&p.mutex)
	slot: u32
	if n := len(p.free); n > 0 {
		slot = p.free[n - 1]
		pop(&p.free)
	} else {
		if p.used >= HANDLE_SLOTS_MAX {
			fail(.Out_Of_Memory, "more than %d live GPU objects of one kind", HANDLE_SLOTS_MAX)
			return 0
		}
		slot = u32(p.used)
		p.used += 1
		if p.pages[slot / POOL_PAGE] == nil do p.pages[slot / POOL_PAGE] = new([POOL_PAGE]Pool_Slot)
	}
	s := pool_slot(p, slot)
	s.object = object
	p.live += 1
	return (s.generation << HANDLE_SLOT_BITS) | (slot + 1)
}

// The object a handle names, or nil for 0, a released handle or one from before the
// pool's last reset.
@(private)
pool_get :: #force_inline proc "contextless" (p: ^Pool, handle: u32) -> rawptr {
	if handle == 0 do return nil
	slot := handle & HANDLE_SLOTS_MAX - 1
	s := pool_slot(p, slot)
	if s == nil || s.object == nil || s.generation & (1 << (32 - HANDLE_SLOT_BITS) - 1) != handle >> HANDLE_SLOT_BITS do return nil
	return s.object
}

// Frees a handle's slot for reuse and returns the object it named, or nil when the
// handle was already stale.
@(private)
pool_remove :: proc(p: ^Pool, handle: u32) -> rawptr {
	if handle == 0 do return nil
	sync.mutex_guard(&p.mutex)
	object := pool_get(p, handle)
	if object == nil do return nil
	slot := handle & HANDLE_SLOTS_MAX - 1
	s := pool_slot(p, slot)
	s.object = nil
	s.generation += 1
	append(&p.free, slot)
	p.live -= 1
	return object
}

// Frees every page; the device is gone, and with it every object the handles named.
@(private)
pool_reset :: proc(p: ^Pool) {
	for page in p.pages do if page != nil do free(page)
	delete(p.free)
	p^ = {}
}

@(private)
pools_reset :: proc() {
	pool_reset(&pools.buffers)
	pool_reset(&pools.transfer_buffers)
	pool_reset(&pools.textures)
	pool_reset(&pools.samplers)
	pool_reset(&pools.shaders)
	pool_reset(&pools.graphics_pipelines)
	pool_reset(&pools.compute_pipelines)
	pool_reset(&pools.readbacks)
}

// The object a handle names, for the backend that made it; nil for none or a stale handle.
@(private)
object :: proc {
	buffer_object,
	transfer_buffer_object,
	texture_object,
	sampler_object,
	shader_object,
	graphics_pipeline_object,
	compute_pipeline_object,
}

@(private)
buffer_object :: #force_inline proc "contextless" (h: Buffer) -> rawptr {return pool_get(&pools.buffers, u32(h))}
@(private)
transfer_buffer_object :: #force_inline proc "contextless" (h: Transfer_Buffer) -> rawptr {return pool_get(&pools.transfer_buffers, u32(h))}
@(private)
texture_object :: #force_inline proc "contextless" (h: Texture) -> rawptr {return pool_get(&pools.textures, u32(h))}
@(private)
sampler_object :: #force_inline proc "contextless" (h: Sampler) -> rawptr {return pool_get(&pools.samplers, u32(h))}
@(private)
shader_object :: #force_inline proc "contextless" (h: Shader) -> rawptr {return pool_get(&pools.shaders, u32(h))}
@(private)
graphics_pipeline_object :: #force_inline proc "contextless" (h: Graphics_Pipeline) -> rawptr {return pool_get(&pools.graphics_pipelines, u32(h))}
@(private)
compute_pipeline_object :: #force_inline proc "contextless" (h: Compute_Pipeline) -> rawptr {return pool_get(&pools.compute_pipelines, u32(h))}
