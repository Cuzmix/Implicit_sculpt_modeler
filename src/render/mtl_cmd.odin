#+build darwin
package render

import "core:mem"

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"
import sdl "vendor:sdl3"

// Command buffers, passes and fences of the Metal backend. A render pass is a render
// command encoder, a compute pass a compute encoder and a copy pass a blit encoder, each
// retained while open. Bindings are
// kept on the command buffer and sent to the encoder at the next draw, at SDL_GPU's Metal
// slots, since where a storage buffer goes depends on the bound pipeline's uniform count.

Mtl_Stage :: enum u8 {
	Vertex,
	Fragment,
	Compute,
}

// A uniform slot's latest push. Metal copies set*Bytes data into the command stream, so a
// copy here is all a push needs.
Mtl_Uniform :: struct {
	data:   [MTL_UNIFORM_RANGE]u8,
	length: u32, // 0 when nothing was pushed this recording
	dirty:  bool,
}

Mtl_Present :: struct {
	window:   ^Mtl_Window,
	drawable: ^CA.MetalDrawable,
	frame:    int,
}

Mtl_Cmd :: struct {
	cb:                ^MTL.CommandBuffer,
	serial:            u64, // the submission's number, once submitted
	stamp:             u64, // this recording's number, which tracked backings remember
	render:            ^MTL.RenderCommandEncoder,
	blit:              ^MTL.BlitCommandEncoder,
	compute:           ^MTL.ComputeCommandEncoder,
	buffers:           [dynamic]^Mtl_Buffer_Backing,
	textures:          [dynamic]^Mtl_Texture_Backing,
	presents:          [dynamic]Mtl_Present,
	pipeline:          ^Mtl_Pipeline,
	index_buffer:      ^MTL.Buffer,
	index_offset:      u32,
	index_type:        MTL.IndexType,
	uniforms:          [Mtl_Stage][4]Mtl_Uniform,
	vertex_storage:    [8]^MTL.Buffer,
	fragment_textures: [16]^MTL.Texture,
	fragment_samplers: [16]^MTL.SamplerState,
	storage_dirty:     bool,
	samplers_dirty:    bool,
	// The open compute pass's bindings, sent at its next dispatch as SDL_GPU sends them.
	// The read-write ones are fixed when the pass begins; each texture is a view of the
	// one mip level and layer bound, ours to release when the pass ends.
	compute_pipeline:  ^Mtl_Compute_Pipeline,
	compute_textures:  [MTL_SAMPLERS]^MTL.Texture,
	compute_samplers:  [MTL_SAMPLERS]^MTL.SamplerState,
	compute_storage:   [MTL_STORAGE_BUFFERS]^MTL.Buffer,
	compute_written:   [MTL_COMPUTE_WRITES]^MTL.Texture,
	compute_rw:        [MTL_COMPUTE_WRITES]^MTL.Buffer,
	// Objects retained until the command buffer has run: acceleration structures, their
	// scratch and instance buffers (mtl_accel.odin).
	kept:              [dynamic]^NS.Object,
	// Buffers a traced kernel reads through their GPU address (mtl_buffer_address), which
	// each traced dispatch declares used, since Metal cannot see them through the address.
	addressed:         [dynamic]^MTL.Buffer,
}

Mtl_Fence :: struct {
	serial: u64,
}

@(private = "file")
mtl_stamps: u64

// ---- Tracking -----------------------------------------------------------------------

mtl_cmd_track_buffer :: proc(cmd: ^Mtl_Cmd, b: ^Mtl_Buffer_Backing) {
	if b.stamp == cmd.stamp do return
	b.stamp = cmd.stamp
	b.refs += 1
	append(&cmd.buffers, b)
}

mtl_cmd_track_texture :: proc(cmd: ^Mtl_Cmd, t: ^Mtl_Texture_Backing) {
	if t.stamp == cmd.stamp do return
	t.stamp = cmd.stamp
	t.refs += 1
	append(&cmd.textures, t)
}

// ---- Command buffers ----------------------------------------------------------------

mtl_cmd_free :: proc(cmd: ^Mtl_Cmd) {
	delete(cmd.buffers)
	delete(cmd.textures)
	delete(cmd.presents)
	delete(cmd.kept)
	delete(cmd.addressed)
	free(cmd)
}

// Lets go of everything a finished (or cancelled) command buffer used and makes it free
// for the next recording.
mtl_cmd_recycle :: proc(cmd: ^Mtl_Cmd) {
	for b in cmd.buffers {
		b.refs -= 1
		mtl_buffer_reap(b.owner)
	}
	for t in cmd.textures {
		t.refs -= 1
		mtl_texture_reap(t.owner)
	}
	clear(&cmd.buffers)
	clear(&cmd.textures)
	for p in cmd.presents do NS.release(p.drawable)
	clear(&cmd.presents)
	for o in cmd.kept do NS.release(o)
	clear(&cmd.kept)
	clear(&cmd.addressed)
	if cmd.render != nil do NS.release(cmd.render)
	if cmd.blit != nil do NS.release(cmd.blit)
	if cmd.compute != nil do NS.release(cmd.compute)
	cmd.render, cmd.blit, cmd.compute = nil, nil, nil
	mtl_compute_views_release(cmd)
	if cmd.cb != nil do NS.release(cmd.cb)
	cmd.cb = nil
	append(&mtl_state.free_cmds, cmd)
}

mtl_acquire_command_buffer :: proc(device: ^sdl.GPUDevice) -> ^sdl.GPUCommandBuffer {
	NS.scoped_autoreleasepool()
	mtl_collect()
	cb := MTL.CommandQueue_commandBuffer(mtl_state.queue)
	if cb == nil {
		sdl.SetError("Metal: no command buffer")
		return nil
	}
	NS.retain(cb)
	cmd := pop(&mtl_state.free_cmds) if len(mtl_state.free_cmds) > 0 else new(Mtl_Cmd)
	cmd.cb = cb
	mtl_stamps += 1
	cmd.stamp = mtl_stamps
	cmd.serial = 0
	cmd.pipeline = nil
	for &stage in cmd.uniforms do for &u in stage {
		u.length = 0
		u.dirty = true
	}
	return (^sdl.GPUCommandBuffer)(cmd)
}

@(private = "file")
mtl_submit :: proc(cmd: ^Mtl_Cmd) -> (u64, bool) {
	NS.scoped_autoreleasepool()
	if cmd.render != nil || cmd.blit != nil || cmd.compute != nil {
		sdl.SetError("Metal: submitted inside a pass")
		return 0, false
	}
	// Each drawable is presented once this command buffer has drawn it, and says when it
	// reached the screen.
	for p in cmd.presents {
		mtl_present_log_add(p.window, p.drawable)
		MTL.CommandBuffer_presentDrawable(cmd.cb, p.drawable)
	}
	MTL.CommandBuffer_commit(cmd.cb)
	mtl_state.submitted += 1
	serial := mtl_state.submitted
	cmd.serial = serial
	for p in cmd.presents {
		p.window.frame_serial[p.frame] = serial
		NS.release(p.drawable)
	}
	clear(&cmd.presents)
	for o in cmd.kept do NS.release(o)
	clear(&cmd.kept)
	clear(&cmd.addressed)
	append(&mtl_state.in_flight, cmd)
	mtl_collect()
	return serial, true
}

mtl_submit_command_buffer :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	_, ok := mtl_submit((^Mtl_Cmd)(command_buffer))
	return ok
}

mtl_submit_command_buffer_and_acquire_fence :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> ^sdl.GPUFence {
	serial, ok := mtl_submit((^Mtl_Cmd)(command_buffer))
	if !ok do return nil
	fence := new(Mtl_Fence)
	fence.serial = serial
	return (^sdl.GPUFence)(fence)
}

// A recording never committed is simply dropped; one holding a drawable is refused, as
// SDL_GPU refuses it, since the window would wait for a frame that never comes.
mtl_cancel_command_buffer :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	cmd := (^Mtl_Cmd)(command_buffer)
	if len(cmd.presents) > 0 {
		sdl.SetError("a command buffer holding a swapchain texture cannot be cancelled")
		return false
	}
	if cmd.render != nil do MTL.CommandEncoder_endEncoding(cmd.render)
	if cmd.blit != nil do MTL.CommandEncoder_endEncoding(cmd.blit)
	if cmd.compute != nil do MTL.CommandEncoder_endEncoding(cmd.compute)
	mtl_cmd_recycle(cmd)
	return true
}

mtl_query_fence :: proc(device: ^sdl.GPUDevice, fence: ^sdl.GPUFence) -> bool {
	mtl_collect()
	return (^Mtl_Fence)(fence).serial <= mtl_state.completed
}

mtl_wait_for_fences :: proc(device: ^sdl.GPUDevice, wait_all: bool, fences: [^]^sdl.GPUFence, num_fences: u32) -> bool {
	if num_fences == 0 do return true
	// Submissions finish in order, so all of them are done when the latest is, and any one
	// when the earliest is.
	serial := (^Mtl_Fence)(fences[0]).serial
	for i in 1 ..< num_fences {
		s := (^Mtl_Fence)(fences[i]).serial
		serial = max(serial, s) if wait_all else min(serial, s)
	}
	return mtl_wait_serial(serial)
}

mtl_release_fence :: proc(device: ^sdl.GPUDevice, fence: ^sdl.GPUFence) {
	free((^Mtl_Fence)(fence))
}

// ---- Uniforms -----------------------------------------------------------------------

@(private = "file")
mtl_push_uniform :: proc(cmd: ^Mtl_Cmd, stage: Mtl_Stage, slot, length: u32, data: rawptr) {
	if length > MTL_UNIFORM_RANGE || slot >= 4 {
		sdl.SetError("Metal: a uniform block is too large or its slot is out of range")
		return
	}
	u := &cmd.uniforms[stage][slot]
	mem.copy(&u.data[0], data, int(length))
	u.length = length
	u.dirty = true
}

mtl_push_vertex_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: u32, data: rawptr, length: u32) {
	mtl_push_uniform((^Mtl_Cmd)(command_buffer), .Vertex, slot_index, length, data)
}

mtl_push_fragment_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: u32, data: rawptr, length: u32) {
	mtl_push_uniform((^Mtl_Cmd)(command_buffer), .Fragment, slot_index, length, data)
}

// Pushed before or inside a compute pass, and kept for the command buffer's later passes.
mtl_push_compute_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: u32, data: rawptr, length: u32) {
	mtl_push_uniform((^Mtl_Cmd)(command_buffer), .Compute, slot_index, length, data)
}

// Sends the bindings the draw needs that changed since the last draw. A uniform slot
// nothing was pushed to gets the whole 4 KiB block, as SDL_GPU binds a whole uniform
// buffer, so the shader never reads past what was bound.
@(private = "file")
mtl_bind_draw :: proc(cmd: ^Mtl_Cmd) -> bool {
	p := cmd.pipeline
	enc := cmd.render
	if p == nil || enc == nil do return false
	c := p.counts
	if cmd.storage_dirty {
		for i in 0 ..< c[2] do MTL.RenderCommandEncoder_setVertexBuffer(enc, cmd.vertex_storage[i], 0, NS.UInteger(c[3] + i))
		cmd.storage_dirty = false
	}
	if cmd.samplers_dirty {
		for i in 0 ..< c[4] {
			MTL.RenderCommandEncoder_setFragmentTexture(enc, cmd.fragment_textures[i], NS.UInteger(i))
			MTL.RenderCommandEncoder_setFragmentSamplerState(enc, cmd.fragment_samplers[i], NS.UInteger(i))
		}
		cmd.samplers_dirty = false
	}
	for i in 0 ..< c[3] {
		u := &cmd.uniforms[.Vertex][i]
		if !u.dirty do continue
		MTL.RenderCommandEncoder_setVertexBytes(enc, u.data[:u.length if u.length > 0 else MTL_UNIFORM_RANGE], NS.UInteger(i))
		u.dirty = false
	}
	for i in 0 ..< c[7] {
		u := &cmd.uniforms[.Fragment][i]
		if !u.dirty do continue
		MTL.RenderCommandEncoder_setFragmentBytes(enc, u.data[:u.length if u.length > 0 else MTL_UNIFORM_RANGE], NS.UInteger(i))
		u.dirty = false
	}
	return true
}

// Marks every binding as needing to reach the encoder again, for a new encoder or pipeline.
@(private = "file")
mtl_bindings_dirty :: proc(cmd: ^Mtl_Cmd) {
	cmd.storage_dirty, cmd.samplers_dirty = true, true
	for &stage in cmd.uniforms do for &u in stage do u.dirty = true
}

// ---- Render passes ------------------------------------------------------------------

@(private = "file")
mtl_load_action :: proc(op: sdl.GPULoadOp) -> MTL.LoadAction {
	switch op {
	case .LOAD:      return .Load
	case .CLEAR:     return .Clear
	case .DONT_CARE: return .DontCare
	}
	return .Load
}

@(private = "file")
mtl_store_action :: proc(op: sdl.GPUStoreOp) -> MTL.StoreAction {
	switch op {
	case .STORE:             return .Store
	case .DONT_CARE:         return .DontCare
	case .RESOLVE:           return .MultisampleResolve
	case .RESOLVE_AND_STORE: return .StoreAndMultisampleResolve
	}
	return .Store
}

mtl_begin_render_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer, color_target_infos: [^]sdl.GPUColorTargetInfo, num_color_targets: u32, depth_stencil_target_info: Maybe(^sdl.GPUDepthStencilTargetInfo)) -> ^sdl.GPURenderPass {
	NS.scoped_autoreleasepool()
	cmd := (^Mtl_Cmd)(command_buffer)
	desc := MTL.RenderPassDescriptor_renderPassDescriptor()
	width, height := max(u32), max(u32)
	colors := MTL.RenderPassDescriptor_colorAttachments(desc)
	for i in 0 ..< num_color_targets {
		info := color_target_infos[i]
		t := (^Mtl_Texture)(info.texture)
		target := mtl_texture_for_write(t, info.cycle)
		mtl_cmd_track_texture(cmd, target)
		width, height = min(width, max(t.info.width >> info.mip_level, 1)), min(height, max(t.info.height >> info.mip_level, 1))
		a := MTL.RenderPassColorAttachmentDescriptorArray_object(colors, NS.UInteger(i))
		MTL.RenderPassAttachmentDescriptor_setTexture(a, target.texture)
		MTL.RenderPassAttachmentDescriptor_setLevel(a, NS.UInteger(info.mip_level))
		MTL.RenderPassAttachmentDescriptor_setSlice(a, NS.UInteger(info.layer_or_depth_plane))
		c := info.clear_color
		MTL.RenderPassColorAttachmentDescriptor_setClearColor(a, {f64(c.r), f64(c.g), f64(c.b), f64(c.a)})
		MTL.RenderPassAttachmentDescriptor_setLoadAction(a, mtl_load_action(info.load_op))
		MTL.RenderPassAttachmentDescriptor_setStoreAction(a, mtl_store_action(info.store_op))
		if info.store_op == .RESOLVE || info.store_op == .RESOLVE_AND_STORE {
			resolve := mtl_texture_for_write((^Mtl_Texture)(info.resolve_texture), info.cycle_resolve_texture)
			mtl_cmd_track_texture(cmd, resolve)
			MTL.RenderPassAttachmentDescriptor_setResolveTexture(a, resolve.texture)
			MTL.RenderPassAttachmentDescriptor_setResolveSlice(a, NS.UInteger(info.resolve_layer))
			MTL.RenderPassAttachmentDescriptor_setResolveLevel(a, NS.UInteger(info.resolve_mip_level))
		}
	}
	if d, ok := depth_stencil_target_info.?; ok && d != nil {
		t := (^Mtl_Texture)(d.texture)
		target := mtl_texture_for_write(t, d.cycle)
		mtl_cmd_track_texture(cmd, target)
		level := u32(d.mip_level)
		width, height = min(width, max(t.info.width >> level, 1)), min(height, max(t.info.height >> level, 1))
		da := MTL.RenderPassDescriptor_depthAttachment(desc)
		MTL.RenderPassAttachmentDescriptor_setTexture(da, target.texture)
		MTL.RenderPassAttachmentDescriptor_setLevel(da, NS.UInteger(level))
		MTL.RenderPassAttachmentDescriptor_setSlice(da, NS.UInteger(d.layer))
		MTL.RenderPassAttachmentDescriptor_setLoadAction(da, mtl_load_action(d.load_op))
		MTL.RenderPassAttachmentDescriptor_setStoreAction(da, mtl_store_action(d.store_op))
		MTL.RenderPassDepthAttachmentDescriptor_setClearDepth(da, f64(d.clear_depth))
		if mtl_is_stencil(t.info.format) {
			// Odin's binding does not declare the stencil attachment as the attachment it
			// is, so it is cast to reach the shared setters.
			sa := MTL.RenderPassDescriptor_stencilAttachment(desc)
			sb := (^MTL.RenderPassAttachmentDescriptor)(sa)
			MTL.RenderPassAttachmentDescriptor_setTexture(sb, target.texture)
			MTL.RenderPassAttachmentDescriptor_setLoadAction(sb, mtl_load_action(d.stencil_load_op))
			MTL.RenderPassAttachmentDescriptor_setStoreAction(sb, mtl_store_action(d.stencil_store_op))
			MTL.RenderPassStencilAttachmentDescriptor_setClearStencil(sa, u32(d.clear_stencil))
		}
	}
	enc := MTL.CommandBuffer_renderCommandEncoderWithDescriptor(cmd.cb, desc)
	if enc == nil {
		sdl.SetError("Metal: the render pass could not begin")
		return nil
	}
	NS.retain(enc)
	cmd.render = enc
	// SDL_GPU's defaults: the viewport and scissor cover the smallest target, with no flip,
	// since Metal's clip space already points up.
	MTL.RenderCommandEncoder_setViewport(enc, {0, 0, f64(width), f64(height), 0, 1})
	MTL.RenderCommandEncoder_setScissorRect(enc, {0, 0, NS.Integer(width), NS.Integer(height)})
	MTL.RenderCommandEncoder_setBlendColorRed(enc, 1, 1, 1, 1)
	MTL.RenderCommandEncoder_setStencilReferenceValue(enc, 0)
	cmd.pipeline = nil
	cmd.vertex_storage = {}
	cmd.fragment_textures = {}
	cmd.fragment_samplers = {}
	mtl_bindings_dirty(cmd)
	return (^sdl.GPURenderPass)(cmd)
}

mtl_end_render_pass :: proc(render_pass: ^sdl.GPURenderPass) {
	cmd := (^Mtl_Cmd)(render_pass)
	MTL.CommandEncoder_endEncoding(cmd.render)
	NS.release(cmd.render)
	cmd.render = nil
	cmd.pipeline = nil
}

mtl_bind_graphics_pipeline :: proc(render_pass: ^sdl.GPURenderPass, graphics_pipeline: ^sdl.GPUGraphicsPipeline) {
	cmd := (^Mtl_Cmd)(render_pass)
	p := (^Mtl_Pipeline)(graphics_pipeline)
	enc := cmd.render
	rs := p.raster
	MTL.RenderCommandEncoder_setRenderPipelineState(enc, p.state)
	MTL.RenderCommandEncoder_setTriangleFillMode(enc, .Lines if rs.fill_mode == .LINE else .Fill)
	cull := MTL.CullMode.None
	switch rs.cull_mode {
	case .NONE:
	case .FRONT: cull = .Front
	case .BACK:  cull = .Back
	}
	MTL.RenderCommandEncoder_setCullMode(enc, cull)
	MTL.RenderCommandEncoder_setFrontFacingWinding(enc, .Clockwise if rs.front_face == .CLOCKWISE else .CounterClockwise)
	MTL.RenderCommandEncoder_setDepthClipMode(enc, .Clip if rs.enable_depth_clip else .Clamp)
	if rs.enable_depth_bias {
		MTL.RenderCommandEncoder_setDepthBias(enc, rs.depth_bias_constant_factor, rs.depth_bias_slope_factor, rs.depth_bias_clamp)
	} else {
		MTL.RenderCommandEncoder_setDepthBias(enc, 0, 0, 0)
	}
	if p.depth_stencil != nil do MTL.RenderCommandEncoder_setDepthStencilState(enc, p.depth_stencil)
	cmd.pipeline = p
	mtl_bindings_dirty(cmd)
}

mtl_bind_vertex_buffers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: u32, bindings: [^]sdl.GPUBufferBinding, num_bindings: u32) {
	cmd := (^Mtl_Cmd)(render_pass)
	for i in 0 ..< num_bindings {
		b := (^Mtl_Buffer)(bindings[i].buffer).active
		mtl_cmd_track_buffer(cmd, b)
		MTL.RenderCommandEncoder_setVertexBuffer(cmd.render, b.buffer, NS.UInteger(bindings[i].offset), NS.UInteger(MTL_FIRST_VERTEX_BUFFER + first_slot + i))
	}
}

mtl_bind_index_buffer :: proc(render_pass: ^sdl.GPURenderPass, #by_ptr binding: sdl.GPUBufferBinding, index_element_size: sdl.GPUIndexElementSize) {
	cmd := (^Mtl_Cmd)(render_pass)
	b := (^Mtl_Buffer)(binding.buffer).active
	mtl_cmd_track_buffer(cmd, b)
	cmd.index_buffer, cmd.index_offset = b.buffer, binding.offset
	cmd.index_type = .UInt32 if index_element_size == ._32BIT else .UInt16
}

mtl_bind_vertex_storage_buffers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: u32, storage_buffers: [^]^sdl.GPUBuffer, num_bindings: u32) {
	cmd := (^Mtl_Cmd)(render_pass)
	for i in 0 ..< num_bindings {
		b := (^Mtl_Buffer)(storage_buffers[i]).active
		mtl_cmd_track_buffer(cmd, b)
		cmd.vertex_storage[first_slot + i] = b.buffer
	}
	cmd.storage_dirty = true
}

mtl_bind_fragment_samplers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: u32, texture_sampler_bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: u32) {
	cmd := (^Mtl_Cmd)(render_pass)
	for i in 0 ..< num_bindings {
		t := (^Mtl_Texture)(texture_sampler_bindings[i].texture).active
		mtl_cmd_track_texture(cmd, t)
		cmd.fragment_textures[first_slot + i] = t.texture
		cmd.fragment_samplers[first_slot + i] = (^MTL.SamplerState)(texture_sampler_bindings[i].sampler)
	}
	cmd.samplers_dirty = true
}

mtl_set_scissor :: proc(render_pass: ^sdl.GPURenderPass, #by_ptr scissor: sdl.Rect) {
	cmd := (^Mtl_Cmd)(render_pass)
	MTL.RenderCommandEncoder_setScissorRect(cmd.render, {NS.Integer(scissor.x), NS.Integer(scissor.y), NS.Integer(max(scissor.w, 0)), NS.Integer(max(scissor.h, 0))})
}

mtl_draw_primitives :: proc(render_pass: ^sdl.GPURenderPass, num_vertices, num_instances, first_vertex, first_instance: u32) {
	cmd := (^Mtl_Cmd)(render_pass)
	if !mtl_bind_draw(cmd) do return
	MTL.RenderCommandEncoder_drawPrimitivesWithInstances(cmd.render, cmd.pipeline.primitive, NS.UInteger(first_vertex), NS.UInteger(num_vertices), NS.UInteger(num_instances), NS.UInteger(first_instance))
}

@(private = "file")
mtl_index_size :: proc(cmd: ^Mtl_Cmd) -> u32 {
	return 4 if cmd.index_type == .UInt32 else 2
}

mtl_draw_indexed_primitives :: proc(render_pass: ^sdl.GPURenderPass, num_indices, num_instances, first_index: u32, vertex_offset: i32, first_instance: u32) {
	cmd := (^Mtl_Cmd)(render_pass)
	if !mtl_bind_draw(cmd) do return
	offset := cmd.index_offset + first_index * mtl_index_size(cmd)
	MTL.RenderCommandEncoder_drawIndexPrimitivesWithBaseVertex(cmd.render, cmd.pipeline.primitive, NS.UInteger(num_indices), cmd.index_type, cmd.index_buffer, NS.UInteger(offset), NS.UInteger(num_instances), NS.Integer(vertex_offset), NS.UInteger(first_instance))
}

// Metal draws one indirect command per call, so SDL_GPU loops over them; so does this.
mtl_draw_indexed_primitives_indirect :: proc(render_pass: ^sdl.GPURenderPass, buffer: ^sdl.GPUBuffer, offset: u32, draw_count: u32) {
	cmd := (^Mtl_Cmd)(render_pass)
	if !mtl_bind_draw(cmd) do return
	b := (^Mtl_Buffer)(buffer).active
	mtl_cmd_track_buffer(cmd, b)
	stride :: u32(size_of(sdl.GPUIndexedIndirectDrawCommand))
	for i in 0 ..< draw_count {
		MTL.RenderCommandEncoder_drawIndexPrimitivesWithIndirect(cmd.render, cmd.pipeline.primitive, cmd.index_type, cmd.index_buffer, NS.UInteger(cmd.index_offset), b.buffer, NS.UInteger(offset + i * stride))
	}
}

// ---- Compute passes -----------------------------------------------------------------

mtl_begin_compute_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer, storage_texture_bindings: [^]sdl.GPUStorageTextureReadWriteBinding, num_storage_texture_bindings: u32, storage_buffer_bindings: [^]sdl.GPUStorageBufferReadWriteBinding, num_storage_buffer_bindings: u32) -> ^sdl.GPUComputePass {
	NS.scoped_autoreleasepool()
	cmd := (^Mtl_Cmd)(command_buffer)
	if num_storage_texture_bindings > MTL_COMPUTE_WRITES || num_storage_buffer_bindings > MTL_COMPUTE_WRITES {
		sdl.SetError("Metal: a compute pass writes more than SDL_GPU allows")
		return nil
	}
	enc := MTL.CommandBuffer_computeCommandEncoder(cmd.cb)
	if enc == nil {
		sdl.SetError("Metal: the compute pass could not begin")
		return nil
	}
	NS.retain(enc)
	cmd.compute = enc
	for i in 0 ..< num_storage_texture_bindings {
		b := storage_texture_bindings[i]
		t := (^Mtl_Texture)(b.texture)
		target := mtl_texture_for_write(t, b.cycle)
		mtl_cmd_track_texture(cmd, target)
		// A view of the one level and layer written, as SDL_GPU binds it; the command
		// buffer keeps it alive after this pass releases it.
		cmd.compute_written[i] = MTL.Texture_newTextureViewWithLevels(target.texture, mtl_pixel_format(t.info.format), .Type2D, {NS.UInteger(b.mip_level), 1}, {NS.UInteger(b.layer), 1})
	}
	for i in 0 ..< num_storage_buffer_bindings {
		b := storage_buffer_bindings[i]
		target := mtl_buffer_for_write((^Mtl_Buffer)(b.buffer), b.cycle)
		mtl_cmd_track_buffer(cmd, target)
		cmd.compute_rw[i] = target.buffer
	}
	cmd.compute_pipeline = nil
	cmd.compute_textures = {}
	cmd.compute_samplers = {}
	cmd.compute_storage = {}
	return (^sdl.GPUComputePass)(cmd)
}

mtl_end_compute_pass :: proc(compute_pass: ^sdl.GPUComputePass) {
	cmd := (^Mtl_Cmd)(compute_pass)
	MTL.CommandEncoder_endEncoding(cmd.compute)
	NS.release(cmd.compute)
	cmd.compute = nil
	cmd.compute_pipeline = nil
	mtl_compute_views_release(cmd)
	cmd.compute_rw = {}
}

@(private = "file")
mtl_compute_views_release :: proc(cmd: ^Mtl_Cmd) {
	for &view in cmd.compute_written {
		if view != nil do NS.release(view)
		view = nil
	}
}

// The read-write textures and buffers go to the pipeline's slots now, since they are the
// pass's; the rest follow at the next dispatch.
mtl_bind_compute_pipeline :: proc(compute_pass: ^sdl.GPUComputePass, compute_pipeline: ^sdl.GPUComputePipeline) {
	cmd := (^Mtl_Cmd)(compute_pass)
	p := (^Mtl_Compute_Pipeline)(compute_pipeline)
	enc := cmd.compute
	MTL.ComputeCommandEncoder_setComputePipelineState(enc, p.state)
	cmd.compute_pipeline = p
	for i in 0 ..< p.readwrite_textures do MTL.ComputeCommandEncoder_setTexture(enc, cmd.compute_written[i], NS.UInteger(p.slots.rw_textures[i]))
	for i in 0 ..< p.readwrite_buffers do MTL.ComputeCommandEncoder_setBuffer(enc, cmd.compute_rw[i], 0, NS.UInteger(p.slots.rw_buffers[i]))
	cmd.storage_dirty, cmd.samplers_dirty = true, true
	for &u in cmd.uniforms[.Compute] do u.dirty = true
}

mtl_bind_compute_samplers :: proc(compute_pass: ^sdl.GPUComputePass, first_slot: u32, texture_sampler_bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: u32) {
	cmd := (^Mtl_Cmd)(compute_pass)
	for i in 0 ..< num_bindings {
		t := (^Mtl_Texture)(texture_sampler_bindings[i].texture).active
		mtl_cmd_track_texture(cmd, t)
		cmd.compute_textures[first_slot + i] = t.texture
		cmd.compute_samplers[first_slot + i] = (^MTL.SamplerState)(texture_sampler_bindings[i].sampler)
	}
	cmd.samplers_dirty = true
}

mtl_bind_compute_storage_buffers :: proc(compute_pass: ^sdl.GPUComputePass, first_slot: u32, storage_buffers: [^]^sdl.GPUBuffer, num_bindings: u32) {
	cmd := (^Mtl_Cmd)(compute_pass)
	for i in 0 ..< num_bindings {
		b := (^Mtl_Buffer)(storage_buffers[i]).active
		mtl_cmd_track_buffer(cmd, b)
		cmd.compute_storage[first_slot + i] = b.buffer
	}
	cmd.storage_dirty = true
}

// Sends what changed since the last dispatch, at the pipeline's slots (SDL_GPU's but for traced kernels). A uniform slot nothing
// was pushed to gets the whole 4 KiB block, as for draws.
@(private = "file")
mtl_bind_dispatch :: proc(cmd: ^Mtl_Cmd) -> bool {
	p := cmd.compute_pipeline
	enc := cmd.compute
	if p == nil || enc == nil do return false
	if cmd.samplers_dirty {
		for i in 0 ..< p.samplers {
			MTL.ComputeCommandEncoder_setTexture(enc, cmd.compute_textures[i], NS.UInteger(p.slots.samplers[i][0]))
			MTL.ComputeCommandEncoder_setSamplerState(enc, cmd.compute_samplers[i], NS.UInteger(p.slots.samplers[i][1]))
		}
		cmd.samplers_dirty = false
	}
	if cmd.storage_dirty {
		for i in 0 ..< p.readonly_buffers do MTL.ComputeCommandEncoder_setBuffer(enc, cmd.compute_storage[i], 0, NS.UInteger(p.slots.ro_buffers[i]))
		cmd.storage_dirty = false
	}
	for i in 0 ..< p.uniforms {
		u := &cmd.uniforms[.Compute][i]
		if !u.dirty do continue
		MTL.ComputeCommandEncoder_setBytes(enc, u.data[:u.length if u.length > 0 else MTL_UNIFORM_RANGE], NS.UInteger(p.slots.uniforms[i]))
		u.dirty = false
	}
	return true
}

mtl_dispatch_compute :: proc(compute_pass: ^sdl.GPUComputePass, groupcount_x, groupcount_y, groupcount_z: u32) {
	cmd := (^Mtl_Cmd)(compute_pass)
	if !mtl_bind_dispatch(cmd) do return
	groups := MTL.Size{NS.Integer(groupcount_x), NS.Integer(groupcount_y), NS.Integer(groupcount_z)}
	MTL.ComputeCommandEncoder_dispatchThreadgroups(cmd.compute, groups, cmd.compute_pipeline.threads)
}

// ---- Copy passes --------------------------------------------------------------------

mtl_begin_copy_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> ^sdl.GPUCopyPass {
	NS.scoped_autoreleasepool()
	cmd := (^Mtl_Cmd)(command_buffer)
	enc := MTL.CommandBuffer_blitCommandEncoder(cmd.cb)
	if enc == nil {
		sdl.SetError("Metal: the copy pass could not begin")
		return nil
	}
	NS.retain(enc)
	cmd.blit = enc
	return (^sdl.GPUCopyPass)(cmd)
}

mtl_end_copy_pass :: proc(copy_pass: ^sdl.GPUCopyPass) {
	cmd := (^Mtl_Cmd)(copy_pass)
	MTL.CommandEncoder_endEncoding(cmd.blit)
	NS.release(cmd.blit)
	cmd.blit = nil
}

mtl_upload_to_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTransferBufferLocation, #by_ptr destination: sdl.GPUBufferRegion, cycle: bool) {
	cmd := (^Mtl_Cmd)(copy_pass)
	src := (^Mtl_Buffer)(source.transfer_buffer).active
	dst := mtl_buffer_for_write((^Mtl_Buffer)(destination.buffer), cycle)
	mtl_cmd_track_buffer(cmd, src)
	mtl_cmd_track_buffer(cmd, dst)
	MTL.BlitCommandEncoder_copyFromBuffer(cmd.blit, src.buffer, NS.UInteger(source.offset), dst.buffer, NS.UInteger(destination.offset), NS.UInteger(destination.size))
}

mtl_upload_to_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureTransferInfo, #by_ptr destination: sdl.GPUTextureRegion, cycle: bool) {
	cmd := (^Mtl_Cmd)(copy_pass)
	src := (^Mtl_Buffer)(source.transfer_buffer).active
	t := (^Mtl_Texture)(destination.texture)
	dst := mtl_texture_for_write(t, cycle)
	mtl_cmd_track_buffer(cmd, src)
	mtl_cmd_track_texture(cmd, dst)
	// Rows of the transfer buffer are `pixels_per_row` texels apart, or packed when 0.
	row := (source.pixels_per_row if source.pixels_per_row > 0 else destination.w) * mtl_texel_size(t.info.format)
	rows := source.rows_per_layer if source.rows_per_layer > 0 else destination.h
	size := MTL.Size{NS.Integer(destination.w), NS.Integer(destination.h), NS.Integer(max(destination.d, 1))}
	origin := MTL.Origin{NS.Integer(destination.x), NS.Integer(destination.y), NS.Integer(destination.z)}
	MTL.BlitCommandEncoder_copyFromBufferEx(cmd.blit, src.buffer, NS.UInteger(source.offset), NS.UInteger(row), NS.UInteger(row * rows), size, dst.texture, NS.UInteger(destination.layer), NS.UInteger(destination.mip_level), origin)
}

mtl_copy_buffer_to_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUBufferLocation, #by_ptr destination: sdl.GPUBufferLocation, size: u32, cycle: bool) {
	cmd := (^Mtl_Cmd)(copy_pass)
	src := (^Mtl_Buffer)(source.buffer).active
	dst := mtl_buffer_for_write((^Mtl_Buffer)(destination.buffer), cycle)
	mtl_cmd_track_buffer(cmd, src)
	mtl_cmd_track_buffer(cmd, dst)
	MTL.BlitCommandEncoder_copyFromBuffer(cmd.blit, src.buffer, NS.UInteger(source.offset), dst.buffer, NS.UInteger(destination.offset), NS.UInteger(size))
}

mtl_copy_texture_to_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureLocation, #by_ptr destination: sdl.GPUTextureLocation, w, h, d: u32, cycle: bool) {
	cmd := (^Mtl_Cmd)(copy_pass)
	src := (^Mtl_Texture)(source.texture).active
	dst := mtl_texture_for_write((^Mtl_Texture)(destination.texture), cycle)
	mtl_cmd_track_texture(cmd, src)
	mtl_cmd_track_texture(cmd, dst)
	size := MTL.Size{NS.Integer(w), NS.Integer(h), NS.Integer(max(d, 1))}
	from := MTL.Origin{NS.Integer(source.x), NS.Integer(source.y), NS.Integer(source.z)}
	to := MTL.Origin{NS.Integer(destination.x), NS.Integer(destination.y), NS.Integer(destination.z)}
	MTL.BlitCommandEncoder_copyFromTextureWithDestinationOrigin(cmd.blit, src.texture, NS.UInteger(source.layer), NS.UInteger(source.mip_level), from, size, dst.texture, NS.UInteger(destination.layer), NS.UInteger(destination.mip_level), to)
}

mtl_download_from_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureRegion, #by_ptr destination: sdl.GPUTextureTransferInfo) {
	cmd := (^Mtl_Cmd)(copy_pass)
	t := (^Mtl_Texture)(source.texture)
	src := t.active
	dst := (^Mtl_Buffer)(destination.transfer_buffer).active
	mtl_cmd_track_texture(cmd, src)
	mtl_cmd_track_buffer(cmd, dst)
	row := (destination.pixels_per_row if destination.pixels_per_row > 0 else source.w) * mtl_texel_size(t.info.format)
	rows := destination.rows_per_layer if destination.rows_per_layer > 0 else source.h
	size := MTL.Size{NS.Integer(source.w), NS.Integer(source.h), NS.Integer(max(source.d, 1))}
	origin := MTL.Origin{NS.Integer(source.x), NS.Integer(source.y), NS.Integer(source.z)}
	MTL.BlitCommandEncoder_copyFromTextureEx(cmd.blit, src.texture, NS.UInteger(source.layer), NS.UInteger(source.mip_level), origin, size, dst.buffer, NS.UInteger(destination.offset), NS.UInteger(row), NS.UInteger(row * rows))
}

mtl_download_from_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUBufferRegion, #by_ptr destination: sdl.GPUTransferBufferLocation) {
	cmd := (^Mtl_Cmd)(copy_pass)
	src := (^Mtl_Buffer)(source.buffer).active
	dst := (^Mtl_Buffer)(destination.transfer_buffer).active
	mtl_cmd_track_buffer(cmd, src)
	mtl_cmd_track_buffer(cmd, dst)
	MTL.BlitCommandEncoder_copyFromBuffer(cmd.blit, src.buffer, NS.UInteger(source.offset), dst.buffer, NS.UInteger(destination.offset), NS.UInteger(source.size))
}

// Metal fills the levels below the first with a filter of its own choosing, as it does for
// SDL_GPU.
mtl_generate_mipmaps_for_texture :: proc(command_buffer: ^sdl.GPUCommandBuffer, texture: ^sdl.GPUTexture) {
	NS.scoped_autoreleasepool()
	cmd := (^Mtl_Cmd)(command_buffer)
	t := (^Mtl_Texture)(texture).active
	mtl_cmd_track_texture(cmd, t)
	enc := MTL.CommandBuffer_blitCommandEncoder(cmd.cb)
	if enc == nil do return
	MTL.BlitCommandEncoder_generateMipmapsForTexture(enc, t.texture)
	MTL.CommandEncoder_endEncoding(enc)
}

// A named group of commands for Xcode's GPU capture, on the open encoder if there is one
// and otherwise on the command buffer, as SDL_GPU's Metal backend places it.
mtl_push_debug_group :: proc(command_buffer: ^sdl.GPUCommandBuffer, name: cstring) {
	NS.scoped_autoreleasepool()
	cmd := (^Mtl_Cmd)(command_buffer)
	label := mtl_string(string(name))
	switch {
	case cmd.render != nil: MTL.CommandEncoder_pushDebugGroup(cmd.render, label)
	case cmd.blit != nil:   MTL.CommandEncoder_pushDebugGroup(cmd.blit, label)
	case cmd.compute != nil: MTL.CommandEncoder_pushDebugGroup(cmd.compute, label)
	case:                   MTL.CommandBuffer_pushDebugGroup(cmd.cb, label)
	}
}

mtl_pop_debug_group :: proc(command_buffer: ^sdl.GPUCommandBuffer) {
	NS.scoped_autoreleasepool()
	cmd := (^Mtl_Cmd)(command_buffer)
	switch {
	case cmd.render != nil: MTL.CommandEncoder_popDebugGroup(cmd.render)
	case cmd.blit != nil:   MTL.CommandEncoder_popDebugGroup(cmd.blit)
	case cmd.compute != nil: MTL.CommandEncoder_popDebugGroup(cmd.compute)
	case:                   MTL.CommandBuffer_popDebugGroup(cmd.cb)
	}
}
