package render

import sdl "vendor:sdl3"

// The GPU seam: every GPU call render makes goes through one of these procs, answered by
// render's own Metal backend (mtl_*.odin) on Apple's platforms and by its own Vulkan backend
// (vk_*.odin) everywhere else. They keep the names and arguments of SDL_GPU's procs, which
// the backends were written to mirror (sdl.CreateGPUTexture is gpu_create_texture), though
// SDL_GPU itself no longer draws.
// The handles stay SDL's types: opaque pointers render only passes back to these procs,
// never dereferences, which each backend points at objects of its own. Nothing in render
// calls an sdl.*GPU* proc; scripts/boundary_check.py enforces it. Every proc that returns
// something is require_results, as SDL_GPU's were, so no failure goes unread.

// The Metal backend exists only where Metal does; elsewhere its branches are not compiled,
// and on Apple's platforms the Vulkan ones are not.
METAL :: ODIN_OS == .Darwin

@(require_results)
gpu_acquire_command_buffer :: proc(device: ^sdl.GPUDevice) -> ^sdl.GPUCommandBuffer {
	when METAL do return mtl_acquire_command_buffer(device)
	else do return vk_acquire_command_buffer(device)
}

// A command buffer whose compute passes run on the compute queue (Gpu_Caps.async_compute),
// submitted with gpu_submit_compute; nil with SDL's error set where there is none. It
// holds compute passes only.
@(require_results)
gpu_acquire_compute_command_buffer :: proc(device: ^sdl.GPUDevice) -> ^sdl.GPUCommandBuffer {
	when METAL {
		sdl.SetError("no compute queue under this backend")
		return nil
	} else {
		return vk_acquire_compute_command_buffer(device)
	}
}

// Submits a gpu_acquire_compute_command_buffer recording. It runs after every graphics
// submission so far; its fence says when it is done, and gpu_wait_on hands it to the
// graphics work that reads what it wrote.
@(require_results)
gpu_submit_compute :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> ^sdl.GPUFence {
	return gpu_submit_command_buffer_and_acquire_fence(command_buffer)
}

// Makes a graphics command buffer wait, at every stage, for the compute submission `fence`
// names before it runs, so it sees what that wrote. Waiting on a fence that has already
// signalled stalls nothing.
gpu_wait_on :: proc(command_buffer: ^sdl.GPUCommandBuffer, fence: ^sdl.GPUFence) {
	when !METAL {
		vk_wait_on(command_buffer, fence)
	}
}

@(require_results)
gpu_async_compute_offered :: proc(device: ^sdl.GPUDevice) -> Async_Compute {
	when METAL do return .Off
	else do return vk_state.async_compute
}

@(require_results)
gpu_acquire_swapchain_texture :: proc(command_buffer: ^sdl.GPUCommandBuffer, window: ^sdl.Window, swapchain_texture: ^^sdl.GPUTexture, swapchain_texture_width, swapchain_texture_height: ^sdl.Uint32) -> bool {
	when METAL do return mtl_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, false)
	else do return vk_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, false)
}

@(require_results)
gpu_begin_compute_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer, storage_texture_bindings: [^]sdl.GPUStorageTextureReadWriteBinding, num_storage_texture_bindings: sdl.Uint32, storage_buffer_bindings: [^]sdl.GPUStorageBufferReadWriteBinding, num_storage_buffer_bindings: sdl.Uint32) -> ^sdl.GPUComputePass {
	when METAL do return mtl_begin_compute_pass(command_buffer, storage_texture_bindings, num_storage_texture_bindings, storage_buffer_bindings, num_storage_buffer_bindings)
	else do return vk_begin_compute_pass(command_buffer, storage_texture_bindings, num_storage_texture_bindings, storage_buffer_bindings, num_storage_buffer_bindings)
}

@(require_results)
gpu_begin_copy_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> ^sdl.GPUCopyPass {
	when METAL do return mtl_begin_copy_pass(command_buffer)
	else do return vk_begin_copy_pass(command_buffer)
}

@(require_results)
gpu_begin_render_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer, color_target_infos: [^]sdl.GPUColorTargetInfo, num_color_targets: sdl.Uint32, depth_stencil_target_info: Maybe(^sdl.GPUDepthStencilTargetInfo)) -> ^sdl.GPURenderPass {
	transient_check_pass(color_target_infos, num_color_targets, depth_stencil_target_info)
	when METAL do return mtl_begin_render_pass(command_buffer, color_target_infos, num_color_targets, depth_stencil_target_info)
	else do return vk_begin_render_pass(command_buffer, color_target_infos, num_color_targets, depth_stencil_target_info)
}

gpu_bind_compute_pipeline :: proc(compute_pass: ^sdl.GPUComputePass, compute_pipeline: ^sdl.GPUComputePipeline) {
	when METAL do mtl_bind_compute_pipeline(compute_pass, compute_pipeline)
	else do vk_bind_compute_pipeline(compute_pass, compute_pipeline)
}

gpu_bind_compute_samplers :: proc(compute_pass: ^sdl.GPUComputePass, first_slot: sdl.Uint32, texture_sampler_bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: sdl.Uint32) {
	for b in texture_sampler_bindings[:num_bindings] do transient_check_use(b.texture, "sampled")
	when METAL do mtl_bind_compute_samplers(compute_pass, first_slot, texture_sampler_bindings, num_bindings)
	else do vk_bind_compute_samplers(compute_pass, first_slot, texture_sampler_bindings, num_bindings)
}

// The textures, in order, of the array a gpu_create_compute_pipeline_array kernel reads; at
// most the capacity it was made with. Only the own Vulkan backend makes such kernels.
gpu_bind_compute_texture_array :: proc(compute_pass: ^sdl.GPUComputePass, bindings: []sdl.GPUTextureSamplerBinding) {
	for b in bindings do transient_check_use(b.texture, "sampled")
	when !METAL {
		vk_bind_compute_texture_array(compute_pass, bindings)
	}
}

gpu_bind_compute_storage_buffers :: proc(compute_pass: ^sdl.GPUComputePass, first_slot: sdl.Uint32, storage_buffers: [^]^sdl.GPUBuffer, num_bindings: sdl.Uint32) {
	when METAL do mtl_bind_compute_storage_buffers(compute_pass, first_slot, storage_buffers, num_bindings)
	else do vk_bind_compute_storage_buffers(compute_pass, first_slot, storage_buffers, num_bindings)
}

gpu_bind_fragment_samplers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: sdl.Uint32, texture_sampler_bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: sdl.Uint32) {
	for b in texture_sampler_bindings[:num_bindings] do transient_check_use(b.texture, "sampled")
	when METAL do mtl_bind_fragment_samplers(render_pass, first_slot, texture_sampler_bindings, num_bindings)
	else do vk_bind_fragment_samplers(render_pass, first_slot, texture_sampler_bindings, num_bindings)
}

gpu_bind_graphics_pipeline :: proc(render_pass: ^sdl.GPURenderPass, graphics_pipeline: ^sdl.GPUGraphicsPipeline) {
	when METAL do mtl_bind_graphics_pipeline(render_pass, graphics_pipeline)
	else do vk_bind_graphics_pipeline(render_pass, graphics_pipeline)
}

gpu_bind_index_buffer :: proc(render_pass: ^sdl.GPURenderPass, #by_ptr binding: sdl.GPUBufferBinding, index_element_size: sdl.GPUIndexElementSize) {
	when METAL do mtl_bind_index_buffer(render_pass, binding, index_element_size)
	else do vk_bind_index_buffer(render_pass, binding, index_element_size)
}

gpu_bind_vertex_buffers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: sdl.Uint32, bindings: [^]sdl.GPUBufferBinding, num_bindings: sdl.Uint32) {
	when METAL do mtl_bind_vertex_buffers(render_pass, first_slot, bindings, num_bindings)
	else do vk_bind_vertex_buffers(render_pass, first_slot, bindings, num_bindings)
}

gpu_bind_vertex_storage_buffers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: sdl.Uint32, storage_buffers: [^]^sdl.GPUBuffer, num_bindings: sdl.Uint32) {
	when METAL do mtl_bind_vertex_storage_buffers(render_pass, first_slot, storage_buffers, num_bindings)
	else do vk_bind_vertex_storage_buffers(render_pass, first_slot, storage_buffers, num_bindings)
}

@(require_results)
gpu_cancel_command_buffer :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	when METAL do return mtl_cancel_command_buffer(command_buffer)
	else do return vk_cancel_command_buffer(command_buffer)
}

@(require_results)
gpu_claim_window_for_device :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) -> bool {
	when METAL do return mtl_claim_window(device, window)
	else do return vk_claim_window(device, window)
}

gpu_copy_buffer_to_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUBufferLocation,         #by_ptr destination: sdl.GPUBufferLocation, size: sdl.Uint32, cycle: bool) {
	when METAL do mtl_copy_buffer_to_buffer(copy_pass, source, destination, size, cycle)
	else do vk_copy_buffer_to_buffer(copy_pass, source, destination, size, cycle)
}

gpu_copy_texture_to_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureLocation,        #by_ptr destination: sdl.GPUTextureLocation, w, h, d: sdl.Uint32, cycle: bool) {
	transient_check_use(source.texture, "copied from")
	transient_check_use(destination.texture, "copied to")
	when METAL do mtl_copy_texture_to_texture(copy_pass, source, destination, w, h, d, cycle)
	else do vk_copy_texture_to_texture(copy_pass, source, destination, w, h, d, cycle)
}

// `accel_input` for a buffer an acceleration structure is built from (gpu_build_blas),
// which only the own Vulkan backend with ray queries marks; elsewhere it changes nothing.
@(require_results)
gpu_create_buffer :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUBufferCreateInfo, accel_input := false) -> ^sdl.GPUBuffer {
	when METAL do return mtl_create_buffer(device, createinfo)
	else do return vk_create_buffer(device, createinfo, accel_input)
}

@(require_results)
gpu_create_compute_pipeline :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUComputePipelineCreateInfo) -> ^sdl.GPUComputePipeline {
	when METAL do return mtl_create_compute_pipeline(device, createinfo)
	else do return vk_create_compute_pipeline(device, createinfo)
}

// A compute pipeline that also reads an array of up to `capacity` sampled textures, indexed
// per thread (set 3, binding 0 in SPIR-V): the own Vulkan backend with descriptor indexing
// only, up to Gpu_Caps.texture_arrays; nil with SDL's error set elsewhere, and the caller
// keeps a kernel with named samplers.
@(require_results)
gpu_create_compute_pipeline_array :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUComputePipelineCreateInfo, capacity: u32) -> ^sdl.GPUComputePipeline {
	when METAL {
		sdl.SetError("texture arrays need the own Vulkan backend")
		return nil
	} else {
		return vk_create_compute_pipeline_array(device, createinfo, capacity)
	}
}

// How many textures one array binding may hold; 0 where gpu_create_compute_pipeline_array
// makes nothing.
@(require_results)
gpu_texture_arrays_offered :: proc(device: ^sdl.GPUDevice) -> u32 {
	when METAL do return 0
	else do return vk_state.texture_arrays
}

// ---- Ray queries (Gpu_Caps.ray_query) -------------------------------------------------
// Acceleration structures the driver builds and kernels trace with ray queries: the own
// Vulkan backend on a device with VK_KHR_ray_query (vk_accel.odin), and the own Metal
// backend on an Apple GPU with Metal 3 and ray tracing (mtl_accel.odin). Elsewhere nothing
// is offered: every build returns nil and the callers keep their own BVH walk.

// A bottom-level structure (a mesh's triangles) or a top-level one (instances of bottom
// levels); only the backend looks inside.
Gpu_Accel :: struct {}

// One geometry of a bottom level: a run of triangles of the index buffer. A geometry that
// is not opaque has its candidates handed to the kernel to confirm (a hidden triangle,
// uploaded as a repeated corner, is turned down there).
Blas_Geometry :: struct {
	first_triangle: u32,
	triangle_count: u32,
	opaque:         bool,
}

// One instance of a top level: a bottom level, where it stands (a similarity, as every
// Draw_Item.model) and a 24-bit number the kernel reads back (CommittedInstanceID).
Tlas_Instance :: struct {
	blas:      ^Gpu_Accel,
	transform: Mat4,
	custom:    u32,
}

@(require_results)
gpu_ray_query_offered :: proc(device: ^sdl.GPUDevice) -> bool {
	when METAL do return mtl_ray_query_offered()
	else do return vk_state.ray_query
}

// Records a bottom-level build over `positions` (3 floats a vertex, `vertex_count` of them)
// and `indices` (u32), both made with accel_input, outside any pass. With `update` and the
// same geometries it refits that structure in place and returns it; otherwise it returns a
// new one, and the caller releases `update`. Nil where nothing is offered or the build
// cannot be made.
@(require_results)
gpu_build_blas :: proc(command_buffer: ^sdl.GPUCommandBuffer, positions, indices: ^sdl.GPUBuffer, vertex_count: u32, geometries: []Blas_Geometry, update: ^Gpu_Accel = nil) -> ^Gpu_Accel {
	when METAL {
		if mtl_ray_query_offered() do return mtl_build_blas(command_buffer, positions, indices, vertex_count, geometries, update)
		return nil
	} else {
		if vk_state.ray_query do return vk_build_blas(command_buffer, positions, indices, vertex_count, geometries, update)
		return nil
	}
}

// Records a top-level build over `instances`, outside any pass, into `update` when it has
// as many instances (returning it), else into a new structure (the caller releases
// `update`). The top level keeps each bottom level it names alive until it is released.
@(require_results)
gpu_build_tlas :: proc(command_buffer: ^sdl.GPUCommandBuffer, instances: []Tlas_Instance, update: ^Gpu_Accel = nil) -> ^Gpu_Accel {
	when METAL {
		if mtl_ray_query_offered() do return mtl_build_tlas(command_buffer, instances, update)
		return nil
	} else {
		if vk_state.ray_query do return vk_build_tlas(command_buffer, instances, update)
		return nil
	}
}

// A compute pipeline that traces against the top level at set 3, binding 0 in SPIR-V, and
// also reads an array of up to `capacity` sampled textures at binding 1 (none for 0); nil
// with SDL's error set where ray queries are not offered. Under Metal the code is slangc's
// Metal source with its slot table (RQ_EXT), and texture arrays are not offered.
@(require_results)
gpu_create_compute_pipeline_traced :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUComputePipelineCreateInfo, capacity: u32 = 0) -> ^sdl.GPUComputePipeline {
	when METAL {
		if mtl_ray_query_offered() && capacity == 0 do return mtl_create_compute_pipeline_traced(device, createinfo)
		sdl.SetError("ray queries need the own Vulkan or Metal backend on a GPU that offers them")
		return nil
	} else {
		return vk_create_compute_pipeline_traced(device, createinfo, capacity)
	}
}

// The top level a gpu_create_compute_pipeline_traced kernel traces against at its next
// dispatch in this pass.
gpu_bind_compute_accel :: proc(compute_pass: ^sdl.GPUComputePass, accel: ^Gpu_Accel) {
	when METAL do mtl_bind_compute_accel(compute_pass, accel)
	else do vk_bind_compute_accel(compute_pass, accel)
}

// Frees a structure once no submitted command buffer and no top level uses it.
gpu_release_accel :: proc(device: ^sdl.GPUDevice, accel: ^Gpu_Accel) {
	when METAL do mtl_release_accel(accel)
	else do if accel != nil do vk_release_accel(accel)
}

// Lets go of the build scratch memory beyond what refits need, once a still view's builds
// are recorded; it goes when they have run. Metal gives each build scratch of its own,
// freed with its command buffer, so there is nothing to trim there.
gpu_accel_trim :: proc(device: ^sdl.GPUDevice) {
	when !METAL {
		if vk_state.ray_query do vk_accel_trim()
	}
}

// Where a buffer made with accel_input lies in the GPU's memory, for a ray query kernel
// that reads it through that address; `command_buffer` keeps it alive until it has run.
// 0 where ray queries are not offered.
@(require_results)
gpu_buffer_address :: proc(command_buffer: ^sdl.GPUCommandBuffer, buffer: ^sdl.GPUBuffer) -> u64 {
	when METAL {
		if mtl_ray_query_offered() do return mtl_buffer_address(command_buffer, buffer)
		return 0
	} else {
		if vk_state.ray_query do return vk_buffer_address(command_buffer, buffer)
		return 0
	}
}

// The GPU memory a structure holds, for budgets and the exit stats.
@(require_results)
gpu_accel_bytes :: proc(accel: ^Gpu_Accel) -> u64 {
	when METAL {
		if accel != nil do return mtl_accel_bytes(accel)
		return 0
	} else {
		if accel != nil do return vk_accel_bytes(accel)
		return 0
	}
}

// A compute pipeline whose arithmetic is IEEE 754's, for kernels that must equal the CPU.
// SPIR-V shaders already are, built with `-fp-mode precise` (their first line says so), so
// only the own Metal backend compiles differently: with fast maths off.
@(require_results)
gpu_create_compute_pipeline_exact :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUComputePipelineCreateInfo) -> ^sdl.GPUComputePipeline {
	when METAL do return mtl_create_compute_pipeline_exact(device, createinfo)
	else do return vk_create_compute_pipeline(device, createinfo)
}

@(require_results)
gpu_create_graphics_pipeline :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUGraphicsPipelineCreateInfo) -> ^sdl.GPUGraphicsPipeline {
	when METAL do return mtl_create_graphics_pipeline(device, createinfo)
	else do return vk_create_graphics_pipeline(device, createinfo)
}

@(require_results)
gpu_create_sampler :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUSamplerCreateInfo) -> ^sdl.GPUSampler {
	when METAL do return mtl_create_sampler(device, createinfo)
	else do return vk_create_sampler(device, createinfo)
}

@(require_results)
gpu_create_shader :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUShaderCreateInfo) -> ^sdl.GPUShader {
	when METAL do return mtl_create_shader(device, createinfo)
	else do return vk_create_shader(device, createinfo)
}

@(require_results)
gpu_create_texture :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUTextureCreateInfo) -> ^sdl.GPUTexture {
	when METAL do return mtl_create_texture(device, createinfo)
	else do return vk_create_texture(device, createinfo)
}

// A render target whose contents live only inside the pass that clears it (transient.odin):
// usage COLOR_TARGET or DEPTH_STENCIL_TARGET alone, never loaded, stored, sampled or copied.
// Memoryless on the own Metal backend, lazily allocated where the own Vulkan backend's
// device offers it (tile GPUs), a plain target otherwise.
@(require_results)
gpu_create_texture_transient :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUTextureCreateInfo) -> (texture: ^sdl.GPUTexture) {
	assert(createinfo.usage <= {.COLOR_TARGET, .DEPTH_STENCIL_TARGET}, "a transient texture is a render target only")
	make_it :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUTextureCreateInfo) -> ^sdl.GPUTexture {
		when METAL do return mtl_create_texture_transient(device, createinfo)
		else do return vk_create_texture_transient(device, createinfo)
	}
	texture = make_it(device, createinfo)
	transient_note(texture)
	return
}

// Whether transient textures save memory: a lazily allocated memory type under the own
// Vulkan backend, any Apple GPU under the own Metal one.
@(require_results)
gpu_transient_targets_offered :: proc(device: ^sdl.GPUDevice) -> bool {
	when METAL do return true
	else do return vk_state.lazy_memory
}

@(require_results)
gpu_create_transfer_buffer :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUTransferBufferCreateInfo) -> ^sdl.GPUTransferBuffer {
	when METAL do return mtl_create_transfer_buffer(device, createinfo)
	else do return vk_create_transfer_buffer(device, createinfo)
}

gpu_destroy_device :: proc(device: ^sdl.GPUDevice) {
	when METAL do mtl_destroy_device(device)
	else do vk_destroy_device(device)
}

gpu_dispatch_compute :: proc(compute_pass: ^sdl.GPUComputePass, groupcount_x, groupcount_y, groupcount_z: sdl.Uint32) {
	when METAL do mtl_dispatch_compute(compute_pass, groupcount_x, groupcount_y, groupcount_z)
	else do vk_dispatch_compute(compute_pass, groupcount_x, groupcount_y, groupcount_z)
}

gpu_download_from_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUBufferRegion,           #by_ptr destination: sdl.GPUTransferBufferLocation) {
	when METAL do mtl_download_from_buffer(copy_pass, source, destination)
	else do vk_download_from_buffer(copy_pass, source, destination)
}

gpu_download_from_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureRegion,          #by_ptr destination: sdl.GPUTextureTransferInfo) {
	transient_check_use(source.texture, "downloaded")
	when METAL do mtl_download_from_texture(copy_pass, source, destination)
	else do vk_download_from_texture(copy_pass, source, destination)
}

gpu_draw_indexed_primitives :: proc(render_pass: ^sdl.GPURenderPass, num_indices: sdl.Uint32,  num_instances: sdl.Uint32, first_index:  sdl.Uint32, vertex_offset: sdl.Sint32, first_instance: sdl.Uint32) {
	when METAL do mtl_draw_indexed_primitives(render_pass, num_indices, num_instances, first_index, vertex_offset, first_instance)
	else do vk_draw_indexed_primitives(render_pass, num_indices, num_instances, first_index, vertex_offset, first_instance)
}

gpu_draw_indexed_primitives_indirect :: proc(render_pass: ^sdl.GPURenderPass, buffer: ^sdl.GPUBuffer, offset: sdl.Uint32, draw_count: sdl.Uint32) {
	when METAL do mtl_draw_indexed_primitives_indirect(render_pass, buffer, offset, draw_count)
	else do vk_draw_indexed_primitives_indirect(render_pass, buffer, offset, draw_count)
}

// An indirect draw whose count a kernel wrote: up to `max_draws` commands from `offset`,
// as many as the u32 at `count_offset` of `count_buffer` says. Only where
// gpu_cull_offered.
gpu_draw_indexed_primitives_indirect_count :: proc(render_pass: ^sdl.GPURenderPass, buffer: ^sdl.GPUBuffer, offset: u32, count_buffer: ^sdl.GPUBuffer, count_offset: u32, max_draws: u32) {
	when !METAL {
		vk_draw_indexed_primitives_indirect_count(render_pass, buffer, offset, count_buffer, count_offset, max_draws)
	}
}

// Whether objects' chunks can be culled on the GPU (gpu_cull.odin): the own Vulkan backend
// with indirect draws that take many commands and read their count from a buffer, so the
// culled-away chunks cost the GPU nothing. Not on a tile GPU (one with lazily allocated
// memory: the tablets' and phones'), whose command processor may read every command up to
// the most a draw may take, until a tablet's numbers say it pays there.
@(require_results)
gpu_cull_offered :: proc(device: ^sdl.GPUDevice) -> bool {
	when METAL do return false
	else do return vk_state.multi_draw && vk_state.indirect_count && !vk_state.lazy_memory
}

gpu_draw_primitives :: proc(render_pass: ^sdl.GPURenderPass, num_vertices: sdl.Uint32, num_instances: sdl.Uint32, first_vertex: sdl.Uint32, first_instance: sdl.Uint32) {
	when METAL do mtl_draw_primitives(render_pass, num_vertices, num_instances, first_vertex, first_instance)
	else do vk_draw_primitives(render_pass, num_vertices, num_instances, first_vertex, first_instance)
}

gpu_end_compute_pass :: proc(compute_pass: ^sdl.GPUComputePass) {
	when METAL do mtl_end_compute_pass(compute_pass)
	else do vk_end_compute_pass(compute_pass)
}

gpu_end_copy_pass :: proc(copy_pass: ^sdl.GPUCopyPass) {
	when METAL do mtl_end_copy_pass(copy_pass)
	else do vk_end_copy_pass(copy_pass)
}

gpu_end_render_pass :: proc(render_pass: ^sdl.GPURenderPass) {
	when METAL do mtl_end_render_pass(render_pass)
	else do vk_end_render_pass(render_pass)
}

@(require_results)
gpu_texture_supports_format :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, type: sdl.GPUTextureType, usage: sdl.GPUTextureUsageFlags) -> bool {
	when METAL do return mtl_texture_supports_format(device, format, type, usage)
	else do return vk_texture_supports_format(device, format, type, usage)
}

@(require_results)
gpu_texture_supports_sample_count :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, sample_count: sdl.GPUSampleCount) -> bool {
	when METAL do return mtl_texture_supports_sample_count(device, format, sample_count)
	else do return vk_texture_supports_sample_count(device, format, sample_count)
}

gpu_generate_mipmaps_for_texture :: proc(command_buffer: ^sdl.GPUCommandBuffer, texture: ^sdl.GPUTexture) {
	transient_check_use(texture, "mipmapped")
	when METAL do mtl_generate_mipmaps_for_texture(command_buffer, texture)
	else do vk_generate_mipmaps_for_texture(command_buffer, texture)
}

@(require_results)
gpu_get_device_driver :: proc(device: ^sdl.GPUDevice) -> cstring {
	when METAL do return mtl_get_device_driver(device)
	else do return vk_get_device_driver(device)
}

@(require_results)
gpu_get_device_properties :: proc(device: ^sdl.GPUDevice) -> sdl.PropertiesID {
	when METAL do return mtl_get_device_properties(device)
	else do return vk_get_device_properties(device)
}

@(require_results)
gpu_get_swapchain_texture_format :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) -> sdl.GPUTextureFormat {
	when METAL do return mtl_get_swapchain_texture_format(device, window)
	else do return vk_get_swapchain_texture_format(device, window)
}

@(require_results)
gpu_map_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer, cycle: bool) -> rawptr {
	when METAL do return mtl_map_transfer_buffer(device, transfer_buffer, cycle)
	else do return vk_map_transfer_buffer(device, transfer_buffer, cycle)
}

gpu_push_compute_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: sdl.Uint32, data: rawptr, length: sdl.Uint32) {
	when METAL do mtl_push_compute_uniform_data(command_buffer, slot_index, data, length)
	else do vk_push_compute_uniform_data(command_buffer, slot_index, data, length)
}

gpu_push_fragment_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: sdl.Uint32, data: rawptr, length: sdl.Uint32) {
	when METAL do mtl_push_fragment_uniform_data(command_buffer, slot_index, data, length)
	else do vk_push_fragment_uniform_data(command_buffer, slot_index, data, length)
}

gpu_push_vertex_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: sdl.Uint32, data: rawptr, length: sdl.Uint32) {
	when METAL do mtl_push_vertex_uniform_data(command_buffer, slot_index, data, length)
	else do vk_push_vertex_uniform_data(command_buffer, slot_index, data, length)
}

@(require_results)
gpu_query_fence :: proc(device: ^sdl.GPUDevice, fence: ^sdl.GPUFence) -> bool {
	when METAL do return mtl_query_fence(device, fence)
	else do return vk_query_fence(device, fence)
}

gpu_release_buffer :: proc(device: ^sdl.GPUDevice, buffer: ^sdl.GPUBuffer) {
	when METAL do mtl_release_buffer(device, buffer)
	else do vk_release_buffer(device, buffer)
}

gpu_release_compute_pipeline :: proc(device: ^sdl.GPUDevice, compute_pipeline: ^sdl.GPUComputePipeline) {
	when METAL do mtl_release_compute_pipeline(device, compute_pipeline)
	else do vk_release_compute_pipeline(device, compute_pipeline)
}

gpu_release_fence :: proc(device: ^sdl.GPUDevice, fence: ^sdl.GPUFence) {
	when METAL do mtl_release_fence(device, fence)
	else do vk_release_fence(device, fence)
}

gpu_release_graphics_pipeline :: proc(device: ^sdl.GPUDevice, graphics_pipeline: ^sdl.GPUGraphicsPipeline) {
	when METAL do mtl_release_graphics_pipeline(device, graphics_pipeline)
	else do vk_release_graphics_pipeline(device, graphics_pipeline)
}

gpu_release_sampler :: proc(device: ^sdl.GPUDevice, sampler: ^sdl.GPUSampler) {
	when METAL do mtl_release_sampler(device, sampler)
	else do vk_release_sampler(device, sampler)
}

gpu_release_shader :: proc(device: ^sdl.GPUDevice, shader: ^sdl.GPUShader) {
	when METAL do mtl_release_shader(device, shader)
	else do vk_release_shader(device, shader)
}

gpu_release_texture :: proc(device: ^sdl.GPUDevice, texture: ^sdl.GPUTexture) {
	transient_forget(texture)
	when METAL do mtl_release_texture(device, texture)
	else do vk_release_texture(device, texture)
}

gpu_release_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer) {
	when METAL do mtl_release_transfer_buffer(device, transfer_buffer)
	else do vk_release_transfer_buffer(device, transfer_buffer)
}

gpu_release_window_from_device :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) {
	when METAL do mtl_release_window(device, window)
	else do vk_release_window(device, window)
}

gpu_set_scissor :: proc(render_pass: ^sdl.GPURenderPass, #by_ptr scissor: sdl.Rect) {
	when METAL do mtl_set_scissor(render_pass, scissor)
	else do vk_set_scissor(render_pass, scissor)
}

gpu_push_debug_group :: proc(command_buffer: ^sdl.GPUCommandBuffer, name: cstring) {
	when METAL do mtl_push_debug_group(command_buffer, name)
	else do vk_push_debug_group(command_buffer, name)
}

gpu_pop_debug_group :: proc(command_buffer: ^sdl.GPUCommandBuffer) {
	when METAL do mtl_pop_debug_group(command_buffer)
	else do vk_pop_debug_group(command_buffer)
}

gpu_set_buffer_name :: proc(device: ^sdl.GPUDevice, buffer: ^sdl.GPUBuffer, text: cstring) {
	when METAL do mtl_set_buffer_name(device, buffer, text)
	else do vk_set_buffer_name(device, buffer, text)
}

gpu_set_texture_name :: proc(device: ^sdl.GPUDevice, texture: ^sdl.GPUTexture, text: cstring) {
	when METAL do mtl_set_texture_name(device, texture, text)
	else do vk_set_texture_name(device, texture, text)
}

@(require_results)
gpu_set_allowed_frames_in_flight :: proc(device: ^sdl.GPUDevice, allowed_frames_in_flight: u32) -> bool {
	when METAL do return mtl_set_allowed_frames_in_flight(device, allowed_frames_in_flight)
	else do return vk_set_allowed_frames_in_flight(device, allowed_frames_in_flight)
}

// When a frame reached the screen, as far as each backend can tell (Gpu_Caps.present_timing).
@(require_results)
gpu_present_timing :: proc(device: ^sdl.GPUDevice) -> Present_Timing {
	when METAL do return .Presented_Handler
	else do return vk_state.present_timing
}

gpu_present_input :: proc(window: ^sdl.Window, input_ns: u64) {
	when METAL do mtl_present_input(window, input_ns)
	else do vk_present_input(window, input_ns)
}

@(require_results)
gpu_present_times :: proc(window: ^sdl.Window, out: []Present_Time) -> int {
	when METAL do return mtl_present_times(window, out)
	else do return vk_present_times(window, out)
}

// Frames presented that never reached the screen, since the device was made; `known` false
// where the backend cannot tell (only the own Metal backend's presented handlers can).
@(require_results)
gpu_frames_dropped :: proc() -> (dropped: u64, known: bool) {
	when METAL do return mtl_frames_dropped(), true
	else do return 0, false
}

// Display-link pacing, which only the own Metal backend has (mtl_link.odin).
@(require_results)
gpu_display_link_offered :: proc() -> bool {
	return METAL
}

gpu_set_display_link :: proc(on: bool) {
	when METAL do mtl_state.link_wanted = on
}

@(require_results)
gpu_display_link_frames :: proc() -> u64 {
	when METAL do return mtl_link_frames()
	else do return 0
}

// Whether gpu_create_buffer_mapped makes buffers: the own Vulkan backend with a shared
// memory type (vk_pick_shared_type), the own Metal backend on unified memory.
@(require_results)
gpu_shared_buffers_offered :: proc(device: ^sdl.GPUDevice) -> bool {
	when METAL do return mtl_shared_buffers_offered()
	else do return vk_state.shared_buffers
}

// A device buffer whose `info.size` bytes the CPU writes through `mapped` before anything
// uses it, then ends with gpu_buffer_filled; nil, nil where the backend cannot, and the
// caller uploads into a plain buffer instead.
@(require_results)
gpu_create_buffer_mapped :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUBufferCreateInfo, accel_input := false) -> (buffer: ^sdl.GPUBuffer, mapped: rawptr) {
	when METAL do return mtl_create_buffer_mapped(device, info)
	else do return vk_create_buffer_mapped(device, info, accel_input)
}

// Ends the fill of a gpu_create_buffer_mapped buffer; the mapped pointer is invalid after.
gpu_buffer_filled :: proc(device: ^sdl.GPUDevice, buffer: ^sdl.GPUBuffer) {
	when !METAL {
		vk_buffer_filled(device, buffer)
	}
}

// The compute kernels' subgroup width (0 when unknown) and whether 64-bit buffer atomics
// work.
@(require_results)
gpu_compute_features :: proc(device: ^sdl.GPUDevice) -> (subgroup_size: u32, int64_atomics: bool) {
	when METAL do return mtl_compute_features()
	else do return vk_state.subgroup_size, vk_state.int64_atomics
}

// GPU timestamps, the own Vulkan backend's only: Apple GPUs sample counters only where a
// pass begins or ends, so the own Metal backend would time passes, not the debug groups
// these timestamps bracket.
@(require_results)
gpu_timestamps_offered :: proc(device: ^sdl.GPUDevice) -> bool {
	when METAL do return false
	else do return vk_state.timing.slots[0].pool != 0
}

gpu_write_timestamp :: proc(command_buffer: ^sdl.GPUCommandBuffer, tag: u8) {
	when !METAL {
		vk_write_timestamp((^Vk_Cmd)(command_buffer), tag)
	}
}

@(require_results)
gpu_timestamps_frame :: proc(device: ^sdl.GPUDevice, out: []Gpu_Timestamp) -> int {
	when METAL do return 0
	else do return vk_timestamps_frame(out)
}

// Pre-rotation: Apple's compositor turns Metal's images at no cost, so only the own Vulkan
// backend's are turned.
@(require_results)
gpu_swapchain_turns :: proc(window: ^sdl.Window) -> int {
	when METAL do return 0
	else do return vk_swapchain_turns(window)
}

@(require_results)
gpu_set_swapchain_parameters :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window, swapchain_composition: sdl.GPUSwapchainComposition, present_mode: sdl.GPUPresentMode) -> bool {
	when METAL do return mtl_set_swapchain_parameters(device, window, swapchain_composition, present_mode)
	else do return vk_set_swapchain_parameters(device, window, swapchain_composition, present_mode)
}

@(require_results)
gpu_submit_command_buffer :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	when METAL do return mtl_submit_command_buffer(command_buffer)
	else do return vk_submit_command_buffer(command_buffer)
}

@(require_results)
gpu_submit_command_buffer_and_acquire_fence :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> ^sdl.GPUFence {
	when METAL do return mtl_submit_command_buffer_and_acquire_fence(command_buffer)
	else do return vk_submit_command_buffer_and_acquire_fence(command_buffer)
}

gpu_unmap_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer) {
	when METAL do mtl_unmap_transfer_buffer(device, transfer_buffer)
	else do vk_unmap_transfer_buffer(device, transfer_buffer)
}

gpu_upload_to_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTransferBufferLocation, #by_ptr destination: sdl.GPUBufferRegion, cycle: bool) {
	when METAL do mtl_upload_to_buffer(copy_pass, source, destination, cycle)
	else do vk_upload_to_buffer(copy_pass, source, destination, cycle)
}

gpu_upload_to_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureTransferInfo,    #by_ptr destination: sdl.GPUTextureRegion, cycle: bool) {
	transient_check_use(destination.texture, "uploaded to")
	when METAL do mtl_upload_to_texture(copy_pass, source, destination, cycle)
	else do vk_upload_to_texture(copy_pass, source, destination, cycle)
}

@(require_results)
gpu_wait_and_acquire_swapchain_texture :: proc(command_buffer: ^sdl.GPUCommandBuffer, window: ^sdl.Window, swapchain_texture: ^^sdl.GPUTexture, swapchain_texture_width, swapchain_texture_height: ^sdl.Uint32) -> bool {
	when METAL do return mtl_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, true)
	else do return vk_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, true)
}

@(require_results)
gpu_wait_for_fences :: proc(device: ^sdl.GPUDevice, wait_all: bool, fences: [^]^sdl.GPUFence, num_fences: sdl.Uint32) -> bool {
	when METAL do return mtl_wait_for_fences(device, wait_all, fences, num_fences)
	else do return vk_wait_for_fences(device, wait_all, fences, num_fences)
}

@(require_results)
gpu_wait_for_idle :: proc(device: ^sdl.GPUDevice) -> bool {
	when METAL do return mtl_wait_for_idle(device)
	else do return vk_wait_for_idle(device)
}

@(require_results)
gpu_window_supports_present_mode :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window, present_mode: sdl.GPUPresentMode) -> bool {
	when METAL do return mtl_window_supports_present_mode(device, window, present_mode)
	else do return vk_window_supports_present_mode(device, window, present_mode)
}
