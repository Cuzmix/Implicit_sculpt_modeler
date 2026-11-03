#+build js
package gpu

import "base:runtime"
import "core:log"
import "core:mem"

import sdl "vendor:sdl3"
import wgpu "vendor:wgpu"

// Command buffers, passes, uploads, downloads and the canvas of the WebGPU backend. A
// command buffer is a command encoder; a render pass and a compute pass are their WebGPU
// encoders, and a copy pass is the command encoder itself, which records copies between
// passes. Bindings are kept on the command buffer and become bind groups at the next draw
// or dispatch, in SDL_GPU's SPIR-V sets as WGSL groups, at the bindings
// scripts/shaders_wgsl.py gives them (wgpu_binding). Uniform pushes go to a uniform chunk
// the recording owns, each at a fresh place, written to the GPU in one call just before
// the submission; uploads are copied out of the transfer buffer as they are recorded into
// a staging buffer the recording owns, and copied from there in the recording's order.

// A recording's uniform memory: a buffer the size of WGPU_UNIFORM_CHUNK (plus one block,
// so any offset in it binds a whole one) with its copy in the page's memory, written to
// the GPU at the submission. The first block stays zero, for slots nothing was pushed to.
Wgpu_Uniform_Chunk :: struct {
	buffer: wgpu.Buffer,
	data:   []u8,
	used:   u32,
	groups: [Wgpu_Stage][5]wgpu.BindGroup, // by the stage's uniform count
}

Wgpu_Staging :: struct {
	buffer: wgpu.Buffer,
	size:   u32,
	used:   u32,
}

// A copy into a transfer buffer that lands once the GPU has written `readback`, rows of
// `row_bytes` taken `gpu_pitch` apart and put `cpu_pitch` apart from `dst_offset`.
Wgpu_Download :: struct {
	readback:   wgpu.Buffer,
	size:       u32,
	dst:        ^Wgpu_Transfer,
	dst_offset: u32,
	rows:       u32,
	row_bytes:  u32,
	gpu_pitch:  u32,
	cpu_pitch:  u32,
	fence:      ^Wgpu_Fence,
}

Wgpu_Uniform_Slot :: struct {
	offset: u32,
	length: u32,
}

Wgpu_Cmd :: struct {
	encoder:           wgpu.CommandEncoder,
	render:            wgpu.RenderPassEncoder,
	compute:           wgpu.ComputePassEncoder,
	recorded:          bool,
	presented:         bool,
	uniforms:          [dynamic]^Wgpu_Uniform_Chunk, // the last is the one pushes go to
	staging:           [dynamic]Wgpu_Staging,
	downloads:         [dynamic]^Wgpu_Download,
	slots:             [Wgpu_Stage][4]Wgpu_Uniform_Slot,
	uniforms_dirty:    [Wgpu_Stage]bool,
	// The open render pass.
	pass_size:         [2]u32,
	pipeline:          ^Wgpu_Pipeline,
	index_size:        u32,
	vertex_storage:    [8]^Wgpu_Buffer,
	fragment_storage:  [8]^Wgpu_Buffer,
	fragment_textures: [16]^Wgpu_Texture,
	fragment_samplers: [16]wgpu.Sampler,
	resources_dirty:   bool,
	// The open compute pass: the read-write bindings it began with, then what is bound.
	compute_pipeline:  ^Wgpu_Compute_Pipeline,
	compute_written:   [8]Storage_Texture_Binding,
	compute_rw:        [8]^Wgpu_Buffer,
	compute_writes:    [2]u32, // how many textures, then buffers
	compute_textures:  [16]^Wgpu_Texture,
	compute_samplers:  [16]wgpu.Sampler,
	compute_storage:   [8]^Wgpu_Buffer,
	compute_dirty:     bool,
}

// ---- Uniform chunks and staging -----------------------------------------------------

@(private = "file")
wgpu_uniform_chunk_get :: proc() -> ^Wgpu_Uniform_Chunk {
	if c, ok := pop_safe(&wgpu_state.free_uniforms); ok {
		c.used = WGPU_UNIFORM_RANGE
		return c
	}
	c := new(Wgpu_Uniform_Chunk)
	size := WGPU_UNIFORM_CHUNK + WGPU_UNIFORM_RANGE
	c.buffer = wgpu.DeviceCreateBuffer(wgpu_state.device, &{usage = {.Uniform, .CopyDst}, size = u64(size)})
	c.data = make([]u8, size, runtime.heap_allocator())
	c.used = WGPU_UNIFORM_RANGE
	return c
}

wgpu_uniform_chunk_free :: proc(c: ^Wgpu_Uniform_Chunk) {
	for stage in c.groups do for g in stage do if g != nil do wgpu.BindGroupRelease(g)
	wgpu.BufferDestroy(c.buffer)
	wgpu.BufferRelease(c.buffer)
	delete(c.data, runtime.heap_allocator())
	free(c)
}

// A place in the recording's staging memory for `size` bytes, 256-byte aligned as copies
// into textures want their rows.
@(private = "file")
wgpu_staging_take :: proc(cmd: ^Wgpu_Cmd, size: u32) -> (wgpu.Buffer, u32) {
	for &s in cmd.staging {
		at := (s.used + 255) &~ 255
		if at + size <= s.size {
			s.used = at + size
			return s.buffer, at
		}
	}
	chunk := max(u32(WGPU_STAGING_CHUNK), (size + 255) &~ 255)
	buffer := wgpu.DeviceCreateBuffer(wgpu_state.device, &{usage = {.CopySrc, .CopyDst}, size = u64(chunk)})
	append(&cmd.staging, Wgpu_Staging{buffer = buffer, size = chunk, used = size})
	return buffer, 0
}

// ---- Command buffers ----------------------------------------------------------------

wgpu_cmd_free :: proc(cmd: ^Wgpu_Cmd) {
	for s in cmd.staging {
		wgpu.BufferDestroy(s.buffer)
		wgpu.BufferRelease(s.buffer)
	}
	delete(cmd.staging)
	delete(cmd.uniforms)
	delete(cmd.downloads)
	free(cmd)
}

// Hands a finished or cancelled recording's uniform chunks back and keeps its staging
// chunks for the next one, but not one made for a single large upload: the queue runs
// every later write after this submission, so reusing them races nothing.
@(private = "file")
wgpu_cmd_recycle :: proc(cmd: ^Wgpu_Cmd) {
	for c in cmd.uniforms do append(&wgpu_state.free_uniforms, c)
	clear(&cmd.uniforms)
	for i := 0; i < len(cmd.staging); {
		s := &cmd.staging[i]
		if s.size > WGPU_STAGING_CHUNK {
			wgpu.BufferDestroy(s.buffer)
			wgpu.BufferRelease(s.buffer)
			unordered_remove(&cmd.staging, i)
			continue
		}
		s.used = 0
		i += 1
	}
	clear(&cmd.downloads)
	cmd.encoder, cmd.render, cmd.compute = nil, nil, nil
	append(&wgpu_state.free_cmds, cmd)
	wgpu_state.open_cmds -= 1
	wgpu_reap()
}

wgpu_acquire_command_buffer :: proc(device: Device) -> Cmd {
	encoder := wgpu.DeviceCreateCommandEncoder(wgpu_state.device)
	if encoder == nil {
		wgpu_fail("WebGPU: no command encoder")
		return nil
	}
	cmd := pop(&wgpu_state.free_cmds) if len(wgpu_state.free_cmds) > 0 else new(Wgpu_Cmd)
	cmd.encoder = encoder
	cmd.recorded, cmd.presented = false, false
	cmd.slots = {}
	cmd.uniforms_dirty = {.Vertex = true, .Fragment = true, .Compute = true}
	cmd.pipeline, cmd.compute_pipeline = nil, nil
	append(&cmd.uniforms, wgpu_uniform_chunk_get())
	wgpu_state.open_cmds += 1
	return (Cmd)(cmd)
}

wgpu_command_buffer_recorded :: proc(command_buffer: Cmd) -> bool {
	cmd := (^Wgpu_Cmd)(command_buffer)
	return cmd.recorded || cmd.presented
}

wgpu_cancel_command_buffer :: proc(command_buffer: Cmd) -> bool {
	cmd := (^Wgpu_Cmd)(command_buffer)
	if cmd.render != nil || cmd.compute != nil {
		wgpu_fail("WebGPU: cancelled inside a pass")
		return false
	}
	wgpu.CommandEncoderRelease(cmd.encoder)
	for d in cmd.downloads {
		wgpu.BufferDestroy(d.readback)
		wgpu.BufferRelease(d.readback)
		free(d)
	}
	wgpu_cmd_recycle(cmd)
	return true
}

@(private = "file")
wgpu_on_done :: proc "c" (status: wgpu.QueueWorkDoneStatus, message: string, userdata1, userdata2: rawptr) {
	context = wgpu_state.ctx
	if status != .Success do log.errorf("WebGPU: a submission failed (%v): %s", status, message)
	wgpu_fence_answered((^Wgpu_Fence)(userdata1))
}

@(private = "file")
wgpu_on_mapped :: proc "c" (status: wgpu.MapAsyncStatus, message: string, userdata1, userdata2: rawptr) {
	context = wgpu_state.ctx
	d := (^Wgpu_Download)(userdata1)
	// wgpu.js answers a failed map twice (its catch, then its then); the first answer
	// settles the download and the second finds it gone.
	if d == nil || d.readback == nil do return
	readback := d.readback
	d.readback = nil
	if status == .Success {
		// wgpu.js copies the mapped range into memory it frees itself on unmap, so it
		// gets memory from the allocator it frees with.
		alloc := runtime.default_context().allocator
		scratch, err := mem.alloc_bytes_non_zeroed(int(d.size), 16, alloc)
		if err == nil {
			_ = wgpu.BufferReadMappedRange(readback, 0, raw_data(scratch), uint(d.size))
			for row in 0 ..< d.rows {
				from := scratch[row * d.gpu_pitch:][:d.row_bytes]
				at := d.dst_offset + row * d.cpu_pitch
				if at + d.row_bytes <= u32(len(d.dst.data)) do copy(d.dst.data[at:], from)
			}
			wgpu.BufferUnmap(readback)
		}
	} else {
		log.errorf("WebGPU: a download could not be read (%v): %s", status, message)
	}
	wgpu.BufferDestroy(readback)
	wgpu.BufferRelease(readback)
	fence := d.fence
	free(d)
	wgpu_fence_answered(fence)
}

@(private = "file")
wgpu_submit :: proc(cmd: ^Wgpu_Cmd, want_fence: bool) -> (^Wgpu_Fence, bool) {
	if cmd.render != nil || cmd.compute != nil {
		wgpu_fail("WebGPU: submitted inside a pass")
		return nil, false
	}
	buffer := wgpu.CommandEncoderFinish(cmd.encoder)
	wgpu.CommandEncoderRelease(cmd.encoder)
	if buffer == nil {
		wgpu_fail("WebGPU: the command buffer could not be finished")
		wgpu_cmd_recycle(cmd)
		return nil, false
	}
	for c in cmd.uniforms do wgpu.QueueWriteBuffer(wgpu_state.queue, c.buffer, 0, raw_data(c.data), uint((c.used + 3) &~ 3))
	wgpu.QueueSubmit(wgpu_state.queue, {buffer})
	wgpu.CommandBufferRelease(buffer)
	fence: ^Wgpu_Fence
	if want_fence || len(cmd.downloads) > 0 {
		fence = new(Wgpu_Fence)
		fence.waiting = 1 + len(cmd.downloads)
		// A fence nobody asked for exists for the downloads alone and goes once they land.
		fence.released = !want_fence
		for d in cmd.downloads {
			d.fence = fence
			wgpu.BufferMapAsync(d.readback, {.Read}, 0, uint(d.size), {callback = wgpu_on_mapped, userdata1 = d})
		}
		wgpu.QueueOnSubmittedWorkDone(wgpu_state.queue, {callback = wgpu_on_done, userdata1 = fence})
	}
	wgpu_cmd_recycle(cmd)
	return fence if want_fence else nil, true
}

wgpu_submit_command_buffer :: proc(command_buffer: Cmd) -> bool {
	_, ok := wgpu_submit((^Wgpu_Cmd)(command_buffer), false)
	return ok
}

wgpu_submit_command_buffer_and_acquire_fence :: proc(command_buffer: Cmd) -> Fence {
	fence, ok := wgpu_submit((^Wgpu_Cmd)(command_buffer), true)
	return (Fence)(fence) if ok else nil
}

// ---- Uniforms -----------------------------------------------------------------------

@(private = "file")
wgpu_push_uniform :: proc(cmd: ^Wgpu_Cmd, stage: Wgpu_Stage, slot, length: u32, data: rawptr) {
	if slot >= 4 do return
	n := min(length, WGPU_UNIFORM_RANGE)
	chunk := cmd.uniforms[len(cmd.uniforms) - 1]
	at := (chunk.used + WGPU_UNIFORM_ALIGN - 1) &~ (WGPU_UNIFORM_ALIGN - 1)
	if at > WGPU_UNIFORM_CHUNK {
		// A new chunk: every slot's latest block comes along, as one bind group names
		// one buffer for all of a stage's slots.
		next := wgpu_uniform_chunk_get()
		for &stage_slots, s in cmd.slots {
			for &u in stage_slots {
				if u.offset == 0 do continue
				to := (next.used + WGPU_UNIFORM_ALIGN - 1) &~ (WGPU_UNIFORM_ALIGN - 1)
				copy(next.data[to:][:u.length], chunk.data[u.offset:][:u.length])
				u.offset, next.used = to, to + u.length
			}
			cmd.uniforms_dirty[s] = true
		}
		append(&cmd.uniforms, next)
		chunk = next
		at = (chunk.used + WGPU_UNIFORM_ALIGN - 1) &~ (WGPU_UNIFORM_ALIGN - 1)
	}
	copy(chunk.data[at:][:n], ([^]u8)(data)[:n])
	chunk.used = at + n
	cmd.slots[stage][slot] = {offset = at, length = n}
	cmd.uniforms_dirty[stage] = true
}

wgpu_push_vertex_uniform_data :: proc(command_buffer: Cmd, slot_index: u32, data: rawptr, length: u32) {
	wgpu_push_uniform((^Wgpu_Cmd)(command_buffer), .Vertex, slot_index, length, data)
}

wgpu_push_fragment_uniform_data :: proc(command_buffer: Cmd, slot_index: u32, data: rawptr, length: u32) {
	wgpu_push_uniform((^Wgpu_Cmd)(command_buffer), .Fragment, slot_index, length, data)
}

wgpu_push_compute_uniform_data :: proc(command_buffer: Cmd, slot_index: u32, data: rawptr, length: u32) {
	wgpu_push_uniform((^Wgpu_Cmd)(command_buffer), .Compute, slot_index, length, data)
}

// The bind group of a stage's `count` uniform blocks in the current chunk, and their
// offsets in it.
@(private = "file")
wgpu_uniform_group :: proc(cmd: ^Wgpu_Cmd, stage: Wgpu_Stage, count: u32) -> (wgpu.BindGroup, [4]u32) {
	chunk := cmd.uniforms[len(cmd.uniforms) - 1]
	c := min(count, 4)
	g := &chunk.groups[stage][c]
	if g^ == nil {
		entries: [4]wgpu.BindGroupEntry
		for i in 0 ..< c do entries[i] = {binding = 2 * i, buffer = chunk.buffer, offset = 0, size = WGPU_UNIFORM_RANGE}
		g^ = wgpu.DeviceCreateBindGroup(wgpu_state.device, &{layout = wgpu_uniform_layout(stage, c), entryCount = uint(c), entries = raw_data(entries[:])})
	}
	offsets: [4]u32
	for i in 0 ..< c do offsets[i] = cmd.slots[stage][i].offset
	return g^, offsets
}

// ---- Resource groups ----------------------------------------------------------------

// Stand-ins bound where the renderer left a slot empty, as WebGPU wants every binding
// its layout names; drawing with one reads zeros, as an unbound slot does elsewhere.
@(private = "file")
Wgpu_Dummies :: struct {
	buffer:  wgpu.Buffer,
	texture: ^Wgpu_Texture,
	sampler: wgpu.Sampler,
}

@(private = "file")
wgpu_dummies: Wgpu_Dummies

@(private = "file")
wgpu_dummy :: proc() -> ^Wgpu_Dummies {
	d := &wgpu_dummies
	if d.buffer == nil {
		d.buffer = wgpu.DeviceCreateBuffer(wgpu_state.device, &{usage = {.Storage, .Uniform, .CopyDst}, size = 256})
		d.texture = (^Wgpu_Texture)(wgpu_create_texture(wgpu_device_handle(), {type = .D2, format = .RGBA8_Unorm, usage = {.Sampled}, width = 1, height = 1, layer_count_or_depth = 1, num_levels = 1}))
		d.sampler = wgpu.DeviceCreateSampler(wgpu_state.device, &{addressModeU = .ClampToEdge, addressModeV = .ClampToEdge, addressModeW = .ClampToEdge, magFilter = .Linear, minFilter = .Linear, mipmapFilter = .Linear, lodMaxClamp = 32, maxAnisotropy = 1})
	}
	return d
}

@(private = "file")
wgpu_buffer_entry :: proc(binding: u32, b: ^Wgpu_Buffer) -> wgpu.BindGroupEntry {
	if b == nil do return {binding = binding, buffer = wgpu_dummy().buffer, size = 256}
	return {binding = binding, buffer = b.buffer, size = u64(max((b.size + 3) &~ 3, 4))}
}

@(private = "file")
wgpu_texture_entry :: proc(binding: u32, t: ^Wgpu_Texture) -> wgpu.BindGroupEntry {
	view := t.view if t != nil && t.view != nil else wgpu_dummy().texture.view
	return {binding = binding, textureView = view}
}

@(private = "file")
wgpu_sampler_entry :: proc(binding: u32, s: wgpu.Sampler) -> wgpu.BindGroupEntry {
	return {binding = binding, sampler = s if s != nil else wgpu_dummy().sampler}
}

// A graphics stage's resource group, from what the recording has bound, by SDL_GPU's
// order: the n-th binding is its samplers, then storage textures, then storage buffers,
// at WGSL binding 2n (and a sampler's sampler at 2n + 1).
@(private = "file")
wgpu_graphics_group :: proc(cmd: ^Wgpu_Cmd, g: ^Wgpu_Group, counts: [4]u32, storage: []^Wgpu_Buffer, textures: []^Wgpu_Texture, samplers: []wgpu.Sampler) -> wgpu.BindGroup {
	if len(g.bindings) == 0 do return wgpu_state.empty_group
	entries := make([]wgpu.BindGroupEntry, len(g.bindings), context.temp_allocator)
	for b, i in g.bindings {
		n := b.binding / 2
		switch {
		case n < counts[0] && b.kind == .Sampler:
			entries[i] = wgpu_sampler_entry(b.binding, samplers[n] if n < u32(len(samplers)) else nil)
		case n < counts[0]:
			entries[i] = wgpu_texture_entry(b.binding, textures[n] if n < u32(len(textures)) else nil)
		case n < counts[0] + counts[1]:
			entries[i] = wgpu_texture_entry(b.binding, nil)
		case:
			k := n - counts[0] - counts[1]
			entries[i] = wgpu_buffer_entry(b.binding, storage[k] if k < u32(len(storage)) else nil)
		}
	}
	return wgpu.DeviceCreateBindGroup(wgpu_state.device, &{layout = g.layout, entryCount = uint(len(entries)), entries = raw_data(entries)})
}

// Sends what changed since the last draw: the resource groups, then the uniform groups
// at their latest offsets.
@(private = "file")
wgpu_bind_draw :: proc(cmd: ^Wgpu_Cmd) -> bool {
	p := cmd.pipeline
	if p == nil || cmd.render == nil do return false
	c := p.counts
	if cmd.resources_dirty {
		vg := wgpu_graphics_group(cmd, &p.vertex, {c[0], c[1], c[2], c[3]}, cmd.vertex_storage[:], nil, nil)
		fg := wgpu_graphics_group(cmd, &p.fragment, {c[4], c[5], c[6], c[7]}, cmd.fragment_storage[:], cmd.fragment_textures[:], cmd.fragment_samplers[:])
		wgpu.RenderPassEncoderSetBindGroup(cmd.render, 0, vg)
		wgpu.RenderPassEncoderSetBindGroup(cmd.render, 2, fg)
		if vg != wgpu_state.empty_group do wgpu.BindGroupRelease(vg)
		if fg != wgpu_state.empty_group do wgpu.BindGroupRelease(fg)
		cmd.resources_dirty = false
	}
	if cmd.uniforms_dirty[.Vertex] {
		if c[3] > 0 {
			g, offsets := wgpu_uniform_group(cmd, .Vertex, c[3])
			wgpu.RenderPassEncoderSetBindGroup(cmd.render, 1, g, offsets[:min(c[3], 4)])
		} else {
			wgpu.RenderPassEncoderSetBindGroup(cmd.render, 1, wgpu_state.empty_group)
		}
		cmd.uniforms_dirty[.Vertex] = false
	}
	if cmd.uniforms_dirty[.Fragment] {
		if c[7] > 0 {
			g, offsets := wgpu_uniform_group(cmd, .Fragment, c[7])
			wgpu.RenderPassEncoderSetBindGroup(cmd.render, 3, g, offsets[:min(c[7], 4)])
		} else {
			wgpu.RenderPassEncoderSetBindGroup(cmd.render, 3, wgpu_state.empty_group)
		}
		cmd.uniforms_dirty[.Fragment] = false
	}
	return true
}

// ---- Render passes ------------------------------------------------------------------

@(private = "file")
wgpu_load :: proc(op: Load_Op) -> wgpu.LoadOp {
	// WebGPU has no "don't care"; a clear costs a tiler nothing more.
	return .Load if op == .Load else .Clear
}

@(private = "file")
wgpu_store :: proc(op: Store_Op) -> wgpu.StoreOp {
	return .Store if op == .Store || op == .Resolve_And_Store else .Discard
}

wgpu_begin_render_pass :: proc(command_buffer: Cmd, color_target_infos: [^]Color_Target, num_color_targets: u32, depth_stencil_target_info: Maybe(^Depth_Target)) -> Render_Pass {
	cmd := (^Wgpu_Cmd)(command_buffer)
	cmd.recorded = true
	width, height := max(u32), max(u32)
	colors := make([]wgpu.RenderPassColorAttachment, int(num_color_targets), context.temp_allocator)
	for i in 0 ..< int(num_color_targets) {
		info := color_target_infos[i]
		t := (^Wgpu_Texture)(info.texture)
		width, height = min(width, max(t.info.width >> info.mip_level, 1)), min(height, max(t.info.height >> info.mip_level, 1))
		c := info.clear_color
		colors[i] = {
			view = wgpu_texture_level(t, info.mip_level),
			depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			loadOp = wgpu_load(info.load_op),
			storeOp = wgpu_store(info.store_op),
			clearValue = {f64(c.r), f64(c.g), f64(c.b), f64(c.a)},
		}
		if info.store_op == .Resolve || info.store_op == .Resolve_And_Store {
			colors[i].resolveTarget = wgpu_texture_level((^Wgpu_Texture)(info.resolve_texture), info.resolve_mip_level)
		}
	}
	depth: wgpu.RenderPassDepthStencilAttachment
	has_depth := false
	if d, ok := depth_stencil_target_info.?; ok && d != nil {
		t := (^Wgpu_Texture)(d.texture)
		level := u32(d.mip_level)
		width, height = min(width, max(t.info.width >> level, 1)), min(height, max(t.info.height >> level, 1))
		depth = {
			view = wgpu_texture_level(t, level),
			depthLoadOp = wgpu_load(d.load_op),
			depthStoreOp = wgpu_store(d.store_op),
			depthClearValue = d.clear_depth,
		}
		if wgpu_is_stencil(t.info.format) {
			depth.stencilLoadOp = wgpu_load(d.stencil_load_op)
			depth.stencilStoreOp = wgpu_store(d.stencil_store_op)
			depth.stencilClearValue = u32(d.clear_stencil)
		}
		has_depth = true
	}
	cmd.render = wgpu.CommandEncoderBeginRenderPass(cmd.encoder, &{
		colorAttachmentCount = uint(len(colors)),
		colorAttachments = raw_data(colors),
		depthStencilAttachment = &depth if has_depth else nil,
	})
	if cmd.render == nil {
		wgpu_fail("WebGPU: the render pass could not begin")
		return nil
	}
	cmd.pass_size = {width, height}
	// SDL_GPU's defaults: the scissor covers the smallest target, and a blend constant of one.
	white := wgpu.Color{1, 1, 1, 1}
	wgpu.RenderPassEncoderSetBlendConstant(cmd.render, &white)
	cmd.pipeline = nil
	cmd.vertex_storage = {}
	cmd.fragment_storage = {}
	cmd.fragment_textures = {}
	cmd.fragment_samplers = {}
	cmd.resources_dirty = true
	cmd.uniforms_dirty[.Vertex], cmd.uniforms_dirty[.Fragment] = true, true
	return (Render_Pass)(cmd)
}

wgpu_end_render_pass :: proc(render_pass: Render_Pass) {
	cmd := (^Wgpu_Cmd)(render_pass)
	wgpu.RenderPassEncoderEnd(cmd.render)
	wgpu.RenderPassEncoderRelease(cmd.render)
	cmd.render = nil
}

wgpu_bind_graphics_pipeline :: proc(render_pass: Render_Pass, graphics_pipeline: Graphics_Pipeline) {
	cmd := (^Wgpu_Cmd)(render_pass)
	p := (^Wgpu_Pipeline)(graphics_pipeline)
	if p == nil || p == cmd.pipeline do return
	cmd.pipeline = p
	wgpu.RenderPassEncoderSetPipeline(cmd.render, p.pipeline)
	cmd.resources_dirty = true
	cmd.uniforms_dirty[.Vertex], cmd.uniforms_dirty[.Fragment] = true, true
}

wgpu_bind_vertex_buffers :: proc(render_pass: Render_Pass, first_slot: u32, bindings: [^]Buffer_Binding, num_bindings: u32) {
	cmd := (^Wgpu_Cmd)(render_pass)
	for i in 0 ..< num_bindings {
		b := (^Wgpu_Buffer)(bindings[i].buffer)
		if b == nil do continue
		offset := bindings[i].offset
		size := (b.size + 3) &~ 3
		wgpu.RenderPassEncoderSetVertexBuffer(cmd.render, first_slot + i, b.buffer, u64(offset), u64(size - min(offset, size)))
	}
}

wgpu_bind_index_buffer :: proc(render_pass: Render_Pass, #by_ptr binding: Buffer_Binding, index_element_size: Index_Size) {
	cmd := (^Wgpu_Cmd)(render_pass)
	b := (^Wgpu_Buffer)(binding.buffer)
	if b == nil do return
	size := (b.size + 3) &~ 3
	format: wgpu.IndexFormat = .Uint16 if index_element_size == .U16 else .Uint32
	cmd.index_size = 2 if format == .Uint16 else 4
	wgpu.RenderPassEncoderSetIndexBuffer(cmd.render, b.buffer, format, u64(binding.offset), u64(size - min(binding.offset, size)))
}

wgpu_bind_vertex_storage_buffers :: proc(render_pass: Render_Pass, first_slot: u32, storage_buffers: [^]Buffer, num_bindings: u32) {
	cmd := (^Wgpu_Cmd)(render_pass)
	for i in 0 ..< num_bindings do if first_slot + i < len(cmd.vertex_storage) do cmd.vertex_storage[first_slot + i] = (^Wgpu_Buffer)(storage_buffers[i])
	cmd.resources_dirty = true
}

wgpu_bind_fragment_storage_buffers :: proc(render_pass: Render_Pass, first_slot: u32, storage_buffers: [^]Buffer, num_bindings: u32) {
	cmd := (^Wgpu_Cmd)(render_pass)
	for i in 0 ..< num_bindings do if first_slot + i < len(cmd.fragment_storage) do cmd.fragment_storage[first_slot + i] = (^Wgpu_Buffer)(storage_buffers[i])
	cmd.resources_dirty = true
}

wgpu_bind_fragment_samplers :: proc(render_pass: Render_Pass, first_slot: u32, texture_sampler_bindings: [^]Texture_Sampler_Binding, num_bindings: u32) {
	cmd := (^Wgpu_Cmd)(render_pass)
	for i in 0 ..< num_bindings {
		slot := first_slot + i
		if slot >= len(cmd.fragment_textures) do continue
		cmd.fragment_textures[slot] = (^Wgpu_Texture)(texture_sampler_bindings[i].texture)
		cmd.fragment_samplers[slot] = wgpu.Sampler(texture_sampler_bindings[i].sampler)
	}
	cmd.resources_dirty = true
}

wgpu_set_scissor :: proc(render_pass: Render_Pass, #by_ptr scissor: sdl.Rect) {
	cmd := (^Wgpu_Cmd)(render_pass)
	// WebGPU refuses a scissor past the target, where SDL_GPU clips it.
	x0 := u32(clamp(scissor.x, 0, i32(cmd.pass_size.x)))
	y0 := u32(clamp(scissor.y, 0, i32(cmd.pass_size.y)))
	x1 := u32(clamp(scissor.x + scissor.w, 0, i32(cmd.pass_size.x)))
	y1 := u32(clamp(scissor.y + scissor.h, 0, i32(cmd.pass_size.y)))
	wgpu.RenderPassEncoderSetScissorRect(cmd.render, x0, y0, max(x1, x0) - x0, max(y1, y0) - y0)
}

wgpu_draw_primitives :: proc(render_pass: Render_Pass, num_vertices, num_instances, first_vertex, first_instance: u32) {
	cmd := (^Wgpu_Cmd)(render_pass)
	if !wgpu_bind_draw(cmd) do return
	wgpu.RenderPassEncoderDraw(cmd.render, num_vertices, num_instances, first_vertex, first_instance)
}

wgpu_draw_indexed_primitives :: proc(render_pass: Render_Pass, num_indices, num_instances, first_index: u32, vertex_offset: i32, first_instance: u32) {
	cmd := (^Wgpu_Cmd)(render_pass)
	if !wgpu_bind_draw(cmd) do return
	wgpu.RenderPassEncoderDrawIndexed(cmd.render, num_indices, num_instances, first_index, vertex_offset, first_instance)
}

// WebGPU draws one indirect command per call, as Metal does.
wgpu_draw_indexed_primitives_indirect :: proc(render_pass: Render_Pass, buffer: Buffer, offset: u32, draw_count: u32) {
	cmd := (^Wgpu_Cmd)(render_pass)
	if !wgpu_bind_draw(cmd) do return
	b := (^Wgpu_Buffer)(buffer)
	stride :: u32(size_of(Indexed_Indirect_Draw))
	for i in 0 ..< draw_count do wgpu.RenderPassEncoderDrawIndexedIndirect(cmd.render, b.buffer, u64(offset + i * stride))
}

wgpu_draw_primitives_indirect :: proc(render_pass: Render_Pass, buffer: Buffer, offset, draw_count, stride: u32) {
	cmd := (^Wgpu_Cmd)(render_pass)
	if !wgpu_bind_draw(cmd) do return
	b := (^Wgpu_Buffer)(buffer)
	for i in 0 ..< draw_count do wgpu.RenderPassEncoderDrawIndirect(cmd.render, b.buffer, u64(offset + i * stride))
}

// ---- Compute passes -----------------------------------------------------------------

wgpu_begin_compute_pass :: proc(command_buffer: Cmd, storage_texture_bindings: [^]Storage_Texture_Binding, num_storage_texture_bindings: u32, storage_buffer_bindings: [^]Storage_Buffer_Binding, num_storage_buffer_bindings: u32) -> Compute_Pass {
	cmd := (^Wgpu_Cmd)(command_buffer)
	cmd.recorded = true
	if num_storage_texture_bindings > 8 || num_storage_buffer_bindings > 8 {
		wgpu_fail("WebGPU: a compute pass writes more than SDL_GPU allows")
		return nil
	}
	for i in 0 ..< num_storage_texture_bindings do cmd.compute_written[i] = storage_texture_bindings[i]
	for i in 0 ..< num_storage_buffer_bindings do cmd.compute_rw[i] = (^Wgpu_Buffer)(storage_buffer_bindings[i].buffer)
	cmd.compute_writes = {num_storage_texture_bindings, num_storage_buffer_bindings}
	cmd.compute = wgpu.CommandEncoderBeginComputePass(cmd.encoder)
	if cmd.compute == nil {
		wgpu_fail("WebGPU: the compute pass could not begin")
		return nil
	}
	cmd.compute_pipeline = nil
	cmd.compute_textures = {}
	cmd.compute_samplers = {}
	cmd.compute_storage = {}
	cmd.compute_dirty = true
	cmd.uniforms_dirty[.Compute] = true
	return (Compute_Pass)(cmd)
}

wgpu_end_compute_pass :: proc(compute_pass: Compute_Pass) {
	cmd := (^Wgpu_Cmd)(compute_pass)
	wgpu.ComputePassEncoderEnd(cmd.compute)
	wgpu.ComputePassEncoderRelease(cmd.compute)
	cmd.compute = nil
}

wgpu_bind_compute_pipeline :: proc(compute_pass: Compute_Pass, compute_pipeline: Compute_Pipeline) {
	cmd := (^Wgpu_Cmd)(compute_pass)
	p := (^Wgpu_Compute_Pipeline)(compute_pipeline)
	if p == nil do return
	cmd.compute_pipeline = p
	wgpu.ComputePassEncoderSetPipeline(cmd.compute, p.pipeline)
	cmd.compute_dirty = true
	cmd.uniforms_dirty[.Compute] = true
}

wgpu_bind_compute_samplers :: proc(compute_pass: Compute_Pass, first_slot: u32, texture_sampler_bindings: [^]Texture_Sampler_Binding, num_bindings: u32) {
	cmd := (^Wgpu_Cmd)(compute_pass)
	for i in 0 ..< num_bindings {
		slot := first_slot + i
		if slot >= len(cmd.compute_textures) do continue
		cmd.compute_textures[slot] = (^Wgpu_Texture)(texture_sampler_bindings[i].texture)
		cmd.compute_samplers[slot] = wgpu.Sampler(texture_sampler_bindings[i].sampler)
	}
	cmd.compute_dirty = true
}

wgpu_bind_compute_storage_buffers :: proc(compute_pass: Compute_Pass, first_slot: u32, storage_buffers: [^]Buffer, num_bindings: u32) {
	cmd := (^Wgpu_Cmd)(compute_pass)
	for i in 0 ..< num_bindings do if first_slot + i < len(cmd.compute_storage) do cmd.compute_storage[first_slot + i] = (^Wgpu_Buffer)(storage_buffers[i])
	cmd.compute_dirty = true
}

@(private = "file")
wgpu_bind_dispatch :: proc(cmd: ^Wgpu_Cmd) -> bool {
	p := cmd.compute_pipeline
	if p == nil || cmd.compute == nil do return false
	info := p.info
	if cmd.compute_dirty {
		// Group 0: samplers, read-only storage textures, read-only storage buffers.
		ro := wgpu_state.empty_group
		if len(p.readonly.bindings) > 0 {
			entries := make([]wgpu.BindGroupEntry, len(p.readonly.bindings), context.temp_allocator)
			for b, i in p.readonly.bindings {
				n := b.binding / 2
				switch {
				case n < info.num_samplers && b.kind == .Sampler: entries[i] = wgpu_sampler_entry(b.binding, cmd.compute_samplers[n] if n < 16 else nil)
				case n < info.num_samplers:                       entries[i] = wgpu_texture_entry(b.binding, cmd.compute_textures[n] if n < 16 else nil)
				case n < info.num_samplers + info.num_readonly_storage_textures: entries[i] = wgpu_texture_entry(b.binding, nil)
				case:
					k := n - info.num_samplers - info.num_readonly_storage_textures
					entries[i] = wgpu_buffer_entry(b.binding, cmd.compute_storage[k] if k < 8 else nil)
				}
			}
			ro = wgpu.DeviceCreateBindGroup(wgpu_state.device, &{layout = p.readonly.layout, entryCount = uint(len(entries)), entries = raw_data(entries)})
		}
		// Group 1: read-write storage textures, then buffers, as the pass began with them.
		rw := wgpu_state.empty_group
		if len(p.readwrite.bindings) > 0 {
			entries := make([]wgpu.BindGroupEntry, len(p.readwrite.bindings), context.temp_allocator)
			for b, i in p.readwrite.bindings {
				n := b.binding / 2
				if n < cmd.compute_writes[0] {
					w := cmd.compute_written[n]
					t := (^Wgpu_Texture)(w.texture)
					entries[i] = {binding = b.binding, textureView = wgpu_texture_level(t, w.mip_level)}
				} else {
					k := n - info.num_readwrite_storage_textures
					entries[i] = wgpu_buffer_entry(b.binding, cmd.compute_rw[k] if k < 8 else nil)
				}
			}
			rw = wgpu.DeviceCreateBindGroup(wgpu_state.device, &{layout = p.readwrite.layout, entryCount = uint(len(entries)), entries = raw_data(entries)})
		}
		wgpu.ComputePassEncoderSetBindGroup(cmd.compute, 0, ro)
		wgpu.ComputePassEncoderSetBindGroup(cmd.compute, 1, rw)
		if ro != wgpu_state.empty_group do wgpu.BindGroupRelease(ro)
		if rw != wgpu_state.empty_group do wgpu.BindGroupRelease(rw)
		cmd.compute_dirty = false
	}
	if cmd.uniforms_dirty[.Compute] {
		if info.num_uniform_buffers > 0 {
			g, offsets := wgpu_uniform_group(cmd, .Compute, info.num_uniform_buffers)
			wgpu.ComputePassEncoderSetBindGroup(cmd.compute, 2, g, offsets[:min(info.num_uniform_buffers, 4)])
		} else {
			wgpu.ComputePassEncoderSetBindGroup(cmd.compute, 2, wgpu_state.empty_group)
		}
		cmd.uniforms_dirty[.Compute] = false
	}
	return true
}

wgpu_dispatch_compute :: proc(compute_pass: Compute_Pass, groupcount_x, groupcount_y, groupcount_z: u32) {
	cmd := (^Wgpu_Cmd)(compute_pass)
	if !wgpu_bind_dispatch(cmd) do return
	wgpu.ComputePassEncoderDispatchWorkgroups(cmd.compute, groupcount_x, groupcount_y, groupcount_z)
}

// ---- Copy passes --------------------------------------------------------------------

wgpu_begin_copy_pass :: proc(command_buffer: Cmd) -> Copy_Pass {
	cmd := (^Wgpu_Cmd)(command_buffer)
	cmd.recorded = true
	return (Copy_Pass)(cmd)
}

wgpu_end_copy_pass :: proc(copy_pass: Copy_Pass) {}

wgpu_upload_to_buffer :: proc(copy_pass: Copy_Pass, #by_ptr source: Transfer_Buffer_Location, #by_ptr destination: Buffer_Region, cycle: bool) {
	cmd := (^Wgpu_Cmd)(copy_pass)
	src := (^Wgpu_Transfer)(source.transfer_buffer)
	dst := (^Wgpu_Buffer)(destination.buffer)
	if src == nil || dst == nil || destination.size == 0 do return
	if destination.offset % 4 != 0 {
		log.errorf("WebGPU: an upload to byte %d of a buffer, which WebGPU copies in words", destination.offset)
		return
	}
	// Whole words: the transfer buffer has 4 bytes to spare and the buffer is made in words.
	size := (destination.size + 3) &~ 3
	staging, at := wgpu_staging_take(cmd, size)
	wgpu.QueueWriteBuffer(wgpu_state.queue, staging, u64(at), &src.data[source.offset], uint(size))
	wgpu.CommandEncoderCopyBufferToBuffer(cmd.encoder, staging, u64(at), dst.buffer, u64(destination.offset), u64(size))
}

wgpu_upload_to_texture :: proc(copy_pass: Copy_Pass, #by_ptr source: Texture_Transfer_Info, #by_ptr destination: Texture_Region, cycle: bool) {
	cmd := (^Wgpu_Cmd)(copy_pass)
	src := (^Wgpu_Transfer)(source.transfer_buffer)
	t := (^Wgpu_Texture)(destination.texture)
	if src == nil || t == nil do return
	texel := wgpu_texel_size(t.info.format)
	row := destination.w * texel
	cpu_pitch := (source.pixels_per_row if source.pixels_per_row > 0 else destination.w) * texel
	gpu_pitch := (row + 255) &~ 255
	rows := destination.h
	size := gpu_pitch * rows
	staging, at := wgpu_staging_take(cmd, size)
	if cpu_pitch == gpu_pitch {
		wgpu.QueueWriteBuffer(wgpu_state.queue, staging, u64(at), &src.data[source.offset], uint(size))
	} else {
		// WebGPU copies rows 256 bytes apart: the rows are laid out so first.
		packed := make([]u8, size, context.temp_allocator)
		for y in 0 ..< rows {
			from := source.offset + y * cpu_pitch
			copy(packed[y * gpu_pitch:][:row], src.data[from:][:row])
		}
		wgpu.QueueWriteBuffer(wgpu_state.queue, staging, u64(at), raw_data(packed), uint(size))
	}
	wgpu.CommandEncoderCopyBufferToTexture(cmd.encoder,
		&{layout = {offset = u64(at), bytesPerRow = gpu_pitch, rowsPerImage = rows}, buffer = staging},
		&{texture = t.texture, mipLevel = destination.mip_level, origin = {destination.x, destination.y, 0}, aspect = .All},
		&{destination.w, destination.h, 1})
}

wgpu_copy_buffer_to_buffer :: proc(copy_pass: Copy_Pass, #by_ptr source: Buffer_Location, #by_ptr destination: Buffer_Location, size: u32, cycle: bool) {
	cmd := (^Wgpu_Cmd)(copy_pass)
	src := (^Wgpu_Buffer)(source.buffer)
	dst := (^Wgpu_Buffer)(destination.buffer)
	if src == nil || dst == nil || size == 0 do return
	wgpu.CommandEncoderCopyBufferToBuffer(cmd.encoder, src.buffer, u64(source.offset), dst.buffer, u64(destination.offset), u64((size + 3) &~ 3))
}

wgpu_copy_texture_to_texture :: proc(copy_pass: Copy_Pass, #by_ptr source: Texture_Location, #by_ptr destination: Texture_Location, w, h, d: u32, cycle: bool) {
	cmd := (^Wgpu_Cmd)(copy_pass)
	src := (^Wgpu_Texture)(source.texture)
	dst := (^Wgpu_Texture)(destination.texture)
	if src == nil || dst == nil do return
	wgpu.CommandEncoderCopyTextureToTexture(cmd.encoder,
		&{texture = src.texture, mipLevel = source.mip_level, origin = {source.x, source.y, 0}, aspect = .All},
		&{texture = dst.texture, mipLevel = destination.mip_level, origin = {destination.x, destination.y, 0}, aspect = .All},
		&{w, h, 1})
}

wgpu_download_from_buffer :: proc(copy_pass: Copy_Pass, #by_ptr source: Buffer_Region, #by_ptr destination: Transfer_Buffer_Location) {
	cmd := (^Wgpu_Cmd)(copy_pass)
	src := (^Wgpu_Buffer)(source.buffer)
	dst := (^Wgpu_Transfer)(destination.transfer_buffer)
	if src == nil || dst == nil || source.size == 0 do return
	size := (source.size + 3) &~ 3
	readback := wgpu.DeviceCreateBuffer(wgpu_state.device, &{usage = {.MapRead, .CopyDst}, size = u64(size)})
	wgpu.CommandEncoderCopyBufferToBuffer(cmd.encoder, src.buffer, u64(source.offset), readback, 0, u64(size))
	d := new(Wgpu_Download)
	d^ = {readback = readback, size = size, dst = dst, dst_offset = destination.offset, rows = 1, row_bytes = source.size, gpu_pitch = size, cpu_pitch = size}
	append(&cmd.downloads, d)
}

wgpu_download_from_texture :: proc(copy_pass: Copy_Pass, #by_ptr source: Texture_Region, #by_ptr destination: Texture_Transfer_Info) {
	cmd := (^Wgpu_Cmd)(copy_pass)
	t := (^Wgpu_Texture)(source.texture)
	dst := (^Wgpu_Transfer)(destination.transfer_buffer)
	if t == nil || dst == nil do return
	texel := wgpu_texel_size(t.info.format)
	row := source.w * texel
	gpu_pitch := (row + 255) &~ 255
	size := gpu_pitch * source.h
	readback := wgpu.DeviceCreateBuffer(wgpu_state.device, &{usage = {.MapRead, .CopyDst}, size = u64(size)})
	wgpu.CommandEncoderCopyTextureToBuffer(cmd.encoder,
		&{texture = t.texture, mipLevel = source.mip_level, origin = {source.x, source.y, 0}, aspect = .All},
		&{layout = {offset = 0, bytesPerRow = gpu_pitch, rowsPerImage = source.h}, buffer = readback},
		&{source.w, source.h, 1})
	d := new(Wgpu_Download)
	cpu_pitch := (destination.pixels_per_row if destination.pixels_per_row > 0 else source.w) * texel
	d^ = {readback = readback, size = size, dst = dst, dst_offset = destination.offset, rows = source.h, row_bytes = row, gpu_pitch = gpu_pitch, cpu_pitch = cpu_pitch}
	append(&cmd.downloads, d)
}

// ---- Mipmaps ------------------------------------------------------------------------

// WebGPU makes no mipmaps itself: each level is drawn from the one above with a linear
// filter, a 2x2 box, as Vulkan's and Metal's blits give.
@(private = "file")
WGPU_MIP_SHADER :: `
@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var smp: sampler;
struct Out { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex fn vs(@builtin(vertex_index) i: u32) -> Out {
	let uv = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u));
	var o: Out;
	o.pos = vec4<f32>(uv * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0), 0.0, 1.0);
	o.uv = uv;
	return o;
}
@fragment fn fs(o: Out) -> @location(0) vec4<f32> {
	return textureSampleLevel(src, smp, o.uv, 0.0);
}
`

@(private = "file")
wgpu_mip_pipeline :: proc(format: wgpu.TextureFormat) -> wgpu.RenderPipeline {
	s := &wgpu_state
	if p, ok := s.mip_pipelines[format]; ok do return p
	if s.mip_module == nil {
		s.mip_module = wgpu.DeviceCreateShaderModule(s.device, &{nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = WGPU_MIP_SHADER}})
		s.mip_sampler = wgpu.DeviceCreateSampler(s.device, &{addressModeU = .ClampToEdge, addressModeV = .ClampToEdge, addressModeW = .ClampToEdge, magFilter = .Linear, minFilter = .Linear, mipmapFilter = .Nearest, lodMaxClamp = 32, maxAnisotropy = 1})
	}
	target := wgpu.ColorTargetState{format = format, writeMask = wgpu.ColorWriteMaskFlags_All}
	p := wgpu.DeviceCreateRenderPipeline(s.device, &{
		vertex = {module = s.mip_module, entryPoint = "vs"},
		primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
		multisample = {count = 1, mask = max(u32)},
		fragment = &{module = s.mip_module, entryPoint = "fs", targetCount = 1, targets = &target},
	})
	s.mip_pipelines[format] = p
	return p
}

wgpu_generate_mipmaps_for_texture :: proc(command_buffer: Cmd, texture: Texture) {
	cmd := (^Wgpu_Cmd)(command_buffer)
	t := (^Wgpu_Texture)(texture)
	if t == nil || t.info.num_levels < 2 || format_is_depth(t.info.format) do return
	cmd.recorded = true
	p := wgpu_mip_pipeline(t.format)
	if p == nil do return
	layout := wgpu.RenderPipelineGetBindGroupLayout(p, 0)
	defer wgpu.BindGroupLayoutRelease(layout)
	for level in 1 ..< t.info.num_levels {
		entries := [2]wgpu.BindGroupEntry{
			{binding = 0, textureView = wgpu_texture_level(t, level - 1)},
			{binding = 1, sampler = wgpu_state.mip_sampler},
		}
		group := wgpu.DeviceCreateBindGroup(wgpu_state.device, &{layout = layout, entryCount = 2, entries = raw_data(entries[:])})
		color := wgpu.RenderPassColorAttachment{view = wgpu_texture_level(t, level), depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = .Clear, storeOp = .Store}
		pass := wgpu.CommandEncoderBeginRenderPass(cmd.encoder, &{colorAttachmentCount = 1, colorAttachments = &color})
		wgpu.RenderPassEncoderSetPipeline(pass, p)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, group)
		wgpu.RenderPassEncoderDraw(pass, 3, 1, 0, 0)
		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)
		wgpu.BindGroupRelease(group)
	}
}

// Debug groups are not sent: WebGPU wants them balanced within each pass, where SDL_GPU
// lets one span a pass's start or end.
wgpu_push_debug_group :: proc(command_buffer: Cmd, name: cstring) {}
wgpu_pop_debug_group :: proc(command_buffer: Cmd) {}

// ---- The canvas ---------------------------------------------------------------------

wgpu_claim_window :: proc(device: Device, window: ^sdl.Window) -> bool {
	return true
}

wgpu_release_window :: proc(device: Device, window: ^sdl.Window) {}

// The canvas presents what the frame drew when the page's task ends; its pace is the
// browser's, the display's refresh.
wgpu_window_supports_present_mode :: proc(device: Device, window: ^sdl.Window, present_mode: Present_Mode) -> bool {
	return present_mode == .Vsync
}

wgpu_set_swapchain_parameters :: proc(device: Device, window: ^sdl.Window, composition: Swapchain_Composition, present_mode: Present_Mode) -> bool {
	if composition != .Sdr && composition != .Sdr_Linear do return false
	srgb := composition == .Sdr_Linear
	if srgb != wgpu_state.srgb {
		wgpu_state.srgb = srgb
		wgpu_state.configured = {}
	}
	return present_mode == .Vsync
}

wgpu_set_allowed_frames_in_flight :: proc(device: Device, frames: u32) -> bool {
	return true
}

@(private = "file")
wgpu_srgb_of :: proc(format: wgpu.TextureFormat) -> wgpu.TextureFormat {
	#partial switch format {
	case .BGRA8Unorm: return .BGRA8UnormSrgb
	case .RGBA8Unorm: return .RGBA8UnormSrgb
	}
	return format
}

wgpu_get_swapchain_texture_format :: proc(device: Device, window: ^sdl.Window) -> Format {
	bgra := wgpu_state.canvas_format == .BGRA8Unorm
	if wgpu_state.srgb do return .BGRA8_Srgb if bgra else .RGBA8_Srgb
	return .BGRA8_Unorm if bgra else .RGBA8_Unorm
}

// The canvas's texture of this frame, the surface configured again first when the page
// changed the canvas's size. A browser always has one, so waiting or not is the same.
wgpu_acquire_swapchain :: proc(command_buffer: Cmd, window: ^sdl.Window, texture: ^Texture, width, height: ^u32, wait: bool) -> bool {
	s := &wgpu_state
	cmd := (^Wgpu_Cmd)(command_buffer)
	if s.configured != s.canvas_size {
		view_format := wgpu_srgb_of(s.canvas_format)
		s.configured = s.canvas_size
		config := wgpu.SurfaceConfiguration {
			device = s.device,
			format = s.canvas_format,
			usage = {.RenderAttachment, .CopySrc},
			width = s.canvas_size.x,
			height = s.canvas_size.y,
			viewFormatCount = 1 if view_format != s.canvas_format else 0,
			viewFormats = &view_format,
			alphaMode = .Opaque,
			presentMode = .Fifo,
		}
		wgpu.SurfaceConfigure(s.surface, &config)
	}
	if s.swapchain == nil do s.swapchain = new(Wgpu_Texture)
	t := s.swapchain
	if t.view != nil do wgpu.TextureViewRelease(t.view)
	if t.texture != nil do wgpu.TextureRelease(t.texture)
	current := wgpu.SurfaceGetCurrentTexture(s.surface)
	if current.texture == nil {
		t^ = {}
		wgpu_fail("WebGPU: the canvas gave no texture")
		return false
	}
	format := wgpu_srgb_of(s.canvas_format) if s.srgb else s.canvas_format
	t^ = {
		texture = current.texture,
		format = format,
		swapchain = true,
		info = {type = .D2, format = wgpu_get_swapchain_texture_format(nil, window), usage = {.Color_Target}, width = s.configured.x, height = s.configured.y, layer_count_or_depth = 1, num_levels = 1},
	}
	t.view = wgpu.TextureCreateView(current.texture, &{format = format, dimension = ._2D, mipLevelCount = 1, arrayLayerCount = 1, aspect = .All})
	texture^ = (Texture)(t)
	width^, height^ = s.configured.x, s.configured.y
	cmd.presented = true
	return true
}
