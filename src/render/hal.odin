package render

import sdl "vendor:sdl3"

// The GPU seam: every SDL_GPU call render makes goes through one of these procs, named
// after SDL's (sdl.CreateGPUTexture is gpu_create_texture) and taking its arguments, so
// another backend (Vulkan, notes/vulkan/backend-design.md; Metal on Apple's platforms) can
// answer them instead.
// The handles stay SDL's types: opaque pointers render only passes back to these procs,
// never dereferences, which a backend may point at objects of its own. Nothing else in
// render calls an sdl.*GPU* proc; scripts/boundary_check.py enforces it.

// The Metal backend exists only where Metal does; elsewhere its branches are not compiled.
METAL :: ODIN_OS == .Darwin

gpu_acquire_command_buffer :: proc(device: ^sdl.GPUDevice) -> ^sdl.GPUCommandBuffer {
	if gpu_backend == .Vulkan do return vk_acquire_command_buffer(device)
	when METAL do if gpu_backend == .Metal do return mtl_acquire_command_buffer(device)
	return sdl.AcquireGPUCommandBuffer(device)
}

// A command buffer whose compute passes run on the compute queue (Gpu_Caps.async_compute),
// submitted with gpu_submit_compute; nil with SDL's error set where there is none. It
// holds compute passes only.
gpu_acquire_compute_command_buffer :: proc(device: ^sdl.GPUDevice) -> ^sdl.GPUCommandBuffer {
	if gpu_backend == .Vulkan do return vk_acquire_compute_command_buffer(device)
	sdl.SetError("no compute queue under this backend")
	return nil
}

// Submits a gpu_acquire_compute_command_buffer recording. It runs after every graphics
// submission so far; its fence says when it is done, and gpu_wait_on hands it to the
// graphics work that reads what it wrote.
gpu_submit_compute :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> ^sdl.GPUFence {
	return gpu_submit_command_buffer_and_acquire_fence(command_buffer)
}

// Makes a graphics command buffer wait, at every stage, for the compute submission `fence`
// names before it runs, so it sees what that wrote. Waiting on a fence that has already
// signalled stalls nothing.
gpu_wait_on :: proc(command_buffer: ^sdl.GPUCommandBuffer, fence: ^sdl.GPUFence) {
	if gpu_backend == .Vulkan do vk_wait_on(command_buffer, fence)
}

gpu_async_compute_offered :: proc(device: ^sdl.GPUDevice) -> Async_Compute {
	return vk_state.async_compute if gpu_backend == .Vulkan else .Off
}

gpu_acquire_swapchain_texture :: proc(command_buffer: ^sdl.GPUCommandBuffer, window: ^sdl.Window, swapchain_texture: ^^sdl.GPUTexture, swapchain_texture_width, swapchain_texture_height: ^sdl.Uint32) -> bool {
	if gpu_backend == .Vulkan do return vk_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, false)
	when METAL do if gpu_backend == .Metal do return mtl_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, false)
	return sdl.AcquireGPUSwapchainTexture(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height)
}

gpu_begin_compute_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer, storage_texture_bindings: [^]sdl.GPUStorageTextureReadWriteBinding, num_storage_texture_bindings: sdl.Uint32, storage_buffer_bindings: [^]sdl.GPUStorageBufferReadWriteBinding, num_storage_buffer_bindings: sdl.Uint32) -> ^sdl.GPUComputePass {
	if gpu_backend == .Vulkan do return vk_begin_compute_pass(command_buffer, storage_texture_bindings, num_storage_texture_bindings, storage_buffer_bindings, num_storage_buffer_bindings)
	when METAL do if gpu_backend == .Metal do return mtl_begin_compute_pass(command_buffer, storage_texture_bindings, num_storage_texture_bindings, storage_buffer_bindings, num_storage_buffer_bindings)
	return sdl.BeginGPUComputePass(command_buffer, storage_texture_bindings, num_storage_texture_bindings, storage_buffer_bindings, num_storage_buffer_bindings)
}

gpu_begin_copy_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> ^sdl.GPUCopyPass {
	if gpu_backend == .Vulkan do return vk_begin_copy_pass(command_buffer)
	when METAL do if gpu_backend == .Metal do return mtl_begin_copy_pass(command_buffer)
	return sdl.BeginGPUCopyPass(command_buffer)
}

gpu_begin_render_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer, color_target_infos: [^]sdl.GPUColorTargetInfo, num_color_targets: sdl.Uint32, depth_stencil_target_info: Maybe(^sdl.GPUDepthStencilTargetInfo)) -> ^sdl.GPURenderPass {
	transient_check_pass(color_target_infos, num_color_targets, depth_stencil_target_info)
	if gpu_backend == .Vulkan do return vk_begin_render_pass(command_buffer, color_target_infos, num_color_targets, depth_stencil_target_info)
	when METAL do if gpu_backend == .Metal do return mtl_begin_render_pass(command_buffer, color_target_infos, num_color_targets, depth_stencil_target_info)
	return sdl.BeginGPURenderPass(command_buffer, color_target_infos, num_color_targets, depth_stencil_target_info)
}

gpu_bind_compute_pipeline :: proc(compute_pass: ^sdl.GPUComputePass, compute_pipeline: ^sdl.GPUComputePipeline) {
	if gpu_backend == .Vulkan {
		vk_bind_compute_pipeline(compute_pass, compute_pipeline)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_bind_compute_pipeline(compute_pass, compute_pipeline)
		return
	}
	sdl.BindGPUComputePipeline(compute_pass, compute_pipeline)
}

gpu_bind_compute_samplers :: proc(compute_pass: ^sdl.GPUComputePass, first_slot: sdl.Uint32, texture_sampler_bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: sdl.Uint32) {
	for b in texture_sampler_bindings[:num_bindings] do transient_check_use(b.texture, "sampled")
	if gpu_backend == .Vulkan {
		vk_bind_compute_samplers(compute_pass, first_slot, texture_sampler_bindings, num_bindings)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_bind_compute_samplers(compute_pass, first_slot, texture_sampler_bindings, num_bindings)
		return
	}
	sdl.BindGPUComputeSamplers(compute_pass, first_slot, texture_sampler_bindings, num_bindings)
}

// The textures, in order, of the array a gpu_create_compute_pipeline_array kernel reads; at
// most the capacity it was made with. Only the own Vulkan backend makes such kernels.
gpu_bind_compute_texture_array :: proc(compute_pass: ^sdl.GPUComputePass, bindings: []sdl.GPUTextureSamplerBinding) {
	for b in bindings do transient_check_use(b.texture, "sampled")
	if gpu_backend == .Vulkan do vk_bind_compute_texture_array(compute_pass, bindings)
}

gpu_bind_compute_storage_buffers :: proc(compute_pass: ^sdl.GPUComputePass, first_slot: sdl.Uint32, storage_buffers: [^]^sdl.GPUBuffer, num_bindings: sdl.Uint32) {
	if gpu_backend == .Vulkan {
		vk_bind_compute_storage_buffers(compute_pass, first_slot, storage_buffers, num_bindings)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_bind_compute_storage_buffers(compute_pass, first_slot, storage_buffers, num_bindings)
		return
	}
	sdl.BindGPUComputeStorageBuffers(compute_pass, first_slot, storage_buffers, num_bindings)
}

gpu_bind_fragment_samplers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: sdl.Uint32, texture_sampler_bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: sdl.Uint32) {
	for b in texture_sampler_bindings[:num_bindings] do transient_check_use(b.texture, "sampled")
	if gpu_backend == .Vulkan {
		vk_bind_fragment_samplers(render_pass, first_slot, texture_sampler_bindings, num_bindings)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_bind_fragment_samplers(render_pass, first_slot, texture_sampler_bindings, num_bindings)
		return
	}
	sdl.BindGPUFragmentSamplers(render_pass, first_slot, texture_sampler_bindings, num_bindings)
}

gpu_bind_graphics_pipeline :: proc(render_pass: ^sdl.GPURenderPass, graphics_pipeline: ^sdl.GPUGraphicsPipeline) {
	if gpu_backend == .Vulkan {
		vk_bind_graphics_pipeline(render_pass, graphics_pipeline)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_bind_graphics_pipeline(render_pass, graphics_pipeline)
		return
	}
	sdl.BindGPUGraphicsPipeline(render_pass, graphics_pipeline)
}

gpu_bind_index_buffer :: proc(render_pass: ^sdl.GPURenderPass, #by_ptr binding: sdl.GPUBufferBinding, index_element_size: sdl.GPUIndexElementSize) {
	if gpu_backend == .Vulkan {
		vk_bind_index_buffer(render_pass, binding, index_element_size)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_bind_index_buffer(render_pass, binding, index_element_size)
		return
	}
	sdl.BindGPUIndexBuffer(render_pass, binding, index_element_size)
}

gpu_bind_vertex_buffers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: sdl.Uint32, bindings: [^]sdl.GPUBufferBinding, num_bindings: sdl.Uint32) {
	if gpu_backend == .Vulkan {
		vk_bind_vertex_buffers(render_pass, first_slot, bindings, num_bindings)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_bind_vertex_buffers(render_pass, first_slot, bindings, num_bindings)
		return
	}
	sdl.BindGPUVertexBuffers(render_pass, first_slot, bindings, num_bindings)
}

gpu_bind_vertex_storage_buffers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: sdl.Uint32, storage_buffers: [^]^sdl.GPUBuffer, num_bindings: sdl.Uint32) {
	if gpu_backend == .Vulkan {
		vk_bind_vertex_storage_buffers(render_pass, first_slot, storage_buffers, num_bindings)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_bind_vertex_storage_buffers(render_pass, first_slot, storage_buffers, num_bindings)
		return
	}
	sdl.BindGPUVertexStorageBuffers(render_pass, first_slot, storage_buffers, num_bindings)
}

gpu_cancel_command_buffer :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	if gpu_backend == .Vulkan do return vk_cancel_command_buffer(command_buffer)
	when METAL do if gpu_backend == .Metal do return mtl_cancel_command_buffer(command_buffer)
	return sdl.CancelGPUCommandBuffer(command_buffer)
}

gpu_claim_window_for_device :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) -> bool {
	if gpu_backend == .Vulkan do return vk_claim_window(device, window)
	when METAL do if gpu_backend == .Metal do return mtl_claim_window(device, window)
	return sdl.ClaimWindowForGPUDevice(device, window)
}

gpu_copy_buffer_to_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUBufferLocation,         #by_ptr destination: sdl.GPUBufferLocation, size: sdl.Uint32, cycle: bool) {
	if gpu_backend == .Vulkan {
		vk_copy_buffer_to_buffer(copy_pass, source, destination, size, cycle)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_copy_buffer_to_buffer(copy_pass, source, destination, size, cycle)
		return
	}
	sdl.CopyGPUBufferToBuffer(copy_pass, source, destination, size, cycle)
}

gpu_copy_texture_to_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureLocation,        #by_ptr destination: sdl.GPUTextureLocation, w, h, d: sdl.Uint32, cycle: bool) {
	transient_check_use(source.texture, "copied from")
	transient_check_use(destination.texture, "copied to")
	if gpu_backend == .Vulkan {
		vk_copy_texture_to_texture(copy_pass, source, destination, w, h, d, cycle)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_copy_texture_to_texture(copy_pass, source, destination, w, h, d, cycle)
		return
	}
	sdl.CopyGPUTextureToTexture(copy_pass, source, destination, w, h, d, cycle)
}

// `accel_input` for a buffer an acceleration structure is built from (gpu_build_blas),
// which only the own Vulkan backend with ray queries marks; elsewhere it changes nothing.
gpu_create_buffer :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUBufferCreateInfo, accel_input := false) -> ^sdl.GPUBuffer {
	if gpu_backend == .Vulkan do return vk_create_buffer(device, createinfo, accel_input)
	when METAL do if gpu_backend == .Metal do return mtl_create_buffer(device, createinfo)
	return sdl.CreateGPUBuffer(device, createinfo)
}

gpu_create_compute_pipeline :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUComputePipelineCreateInfo) -> ^sdl.GPUComputePipeline {
	if gpu_backend == .Vulkan do return vk_create_compute_pipeline(device, createinfo)
	when METAL do if gpu_backend == .Metal do return mtl_create_compute_pipeline(device, createinfo)
	return sdl.CreateGPUComputePipeline(device, createinfo)
}

// A compute pipeline that also reads an array of up to `capacity` sampled textures, indexed
// per thread (set 3, binding 0 in SPIR-V): the own Vulkan backend with descriptor indexing
// only, up to Gpu_Caps.texture_arrays; nil with SDL's error set elsewhere, and the caller
// keeps a kernel with named samplers.
gpu_create_compute_pipeline_array :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUComputePipelineCreateInfo, capacity: u32) -> ^sdl.GPUComputePipeline {
	if gpu_backend == .Vulkan do return vk_create_compute_pipeline_array(device, createinfo, capacity)
	sdl.SetError("texture arrays need the own Vulkan backend")
	return nil
}

// How many textures one array binding may hold; 0 where gpu_create_compute_pipeline_array
// makes nothing.
gpu_texture_arrays_offered :: proc(device: ^sdl.GPUDevice) -> u32 {
	return vk_state.texture_arrays if gpu_backend == .Vulkan else 0
}

// ---- Ray queries (Gpu_Caps.ray_query) -------------------------------------------------
// Acceleration structures the driver builds and kernels trace with ray queries: the own
// Vulkan backend on a device with VK_KHR_ray_query only (vk_accel.odin). Elsewhere nothing
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

gpu_ray_query_offered :: proc(device: ^sdl.GPUDevice) -> bool {
	return gpu_backend == .Vulkan && vk_state.ray_query
}

// Records a bottom-level build over `positions` (3 floats a vertex, `vertex_count` of them)
// and `indices` (u32), both made with accel_input, outside any pass. With `update` and the
// same geometries it refits that structure in place and returns it; otherwise it returns a
// new one, and the caller releases `update`. Nil where nothing is offered or the build
// cannot be made.
gpu_build_blas :: proc(command_buffer: ^sdl.GPUCommandBuffer, positions, indices: ^sdl.GPUBuffer, vertex_count: u32, geometries: []Blas_Geometry, update: ^Gpu_Accel = nil) -> ^Gpu_Accel {
	if gpu_backend == .Vulkan && vk_state.ray_query do return vk_build_blas(command_buffer, positions, indices, vertex_count, geometries, update)
	return nil
}

// Records a top-level build over `instances`, outside any pass, into `update` when it has
// as many instances (returning it), else into a new structure (the caller releases
// `update`). The top level keeps each bottom level it names alive until it is released.
gpu_build_tlas :: proc(command_buffer: ^sdl.GPUCommandBuffer, instances: []Tlas_Instance, update: ^Gpu_Accel = nil) -> ^Gpu_Accel {
	if gpu_backend == .Vulkan && vk_state.ray_query do return vk_build_tlas(command_buffer, instances, update)
	return nil
}

// A compute pipeline that traces against the top level at set 3, binding 0 in SPIR-V, and
// also reads an array of up to `capacity` sampled textures at binding 1 (none for 0); nil
// with SDL's error set where ray queries are not offered.
gpu_create_compute_pipeline_traced :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUComputePipelineCreateInfo, capacity: u32 = 0) -> ^sdl.GPUComputePipeline {
	if gpu_backend == .Vulkan do return vk_create_compute_pipeline_traced(device, createinfo, capacity)
	sdl.SetError("ray queries need the own Vulkan backend")
	return nil
}

// The top level a gpu_create_compute_pipeline_traced kernel traces against at its next
// dispatch in this pass.
gpu_bind_compute_accel :: proc(compute_pass: ^sdl.GPUComputePass, accel: ^Gpu_Accel) {
	if gpu_backend == .Vulkan do vk_bind_compute_accel(compute_pass, accel)
}

// Frees a structure once no submitted command buffer and no top level uses it.
gpu_release_accel :: proc(device: ^sdl.GPUDevice, accel: ^Gpu_Accel) {
	if gpu_backend == .Vulkan && accel != nil do vk_release_accel(accel)
}

// The GPU memory a structure holds, for budgets and the exit stats.
gpu_accel_bytes :: proc(accel: ^Gpu_Accel) -> u64 {
	if gpu_backend == .Vulkan && accel != nil do return vk_accel_bytes(accel)
	return 0
}

// A compute pipeline whose arithmetic is IEEE 754's, for kernels that must equal the CPU.
// SPIR-V shaders already are, built with `-fp-mode precise` (their first line says so), so
// only the own Metal backend compiles differently: with fast maths off. SDL_GPU's Metal
// backend cannot, so it makes the ordinary pipeline and gpu_exact_compute says false.
gpu_create_compute_pipeline_exact :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUComputePipelineCreateInfo) -> ^sdl.GPUComputePipeline {
	when METAL do if gpu_backend == .Metal do return mtl_create_compute_pipeline_exact(device, createinfo)
	return gpu_create_compute_pipeline(device, createinfo)
}

// Whether gpu_create_compute_pipeline_exact keeps its promise: everywhere but SDL_GPU on
// Metal, which compiles every shader with fast maths.
gpu_exact_compute :: proc(device: ^sdl.GPUDevice) -> bool {
	return gpu_backend != .SDL_GPU || gpu_get_device_driver(device) != "metal"
}

gpu_create_device :: proc(format_flags: sdl.GPUShaderFormat, debug_mode: bool, name: cstring) -> ^sdl.GPUDevice {
	return sdl.CreateGPUDevice(format_flags, debug_mode, name)
}

gpu_create_device_with_properties :: proc(props: sdl.PropertiesID) -> ^sdl.GPUDevice {
	return sdl.CreateGPUDeviceWithProperties(props)
}

gpu_create_graphics_pipeline :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUGraphicsPipelineCreateInfo) -> ^sdl.GPUGraphicsPipeline {
	if gpu_backend == .Vulkan do return vk_create_graphics_pipeline(device, createinfo)
	when METAL do if gpu_backend == .Metal do return mtl_create_graphics_pipeline(device, createinfo)
	return sdl.CreateGPUGraphicsPipeline(device, createinfo)
}

gpu_create_sampler :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUSamplerCreateInfo) -> ^sdl.GPUSampler {
	if gpu_backend == .Vulkan do return vk_create_sampler(device, createinfo)
	when METAL do if gpu_backend == .Metal do return mtl_create_sampler(device, createinfo)
	return sdl.CreateGPUSampler(device, createinfo)
}

gpu_create_shader :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUShaderCreateInfo) -> ^sdl.GPUShader {
	if gpu_backend == .Vulkan do return vk_create_shader(device, createinfo)
	when METAL do if gpu_backend == .Metal do return mtl_create_shader(device, createinfo)
	return sdl.CreateGPUShader(device, createinfo)
}

gpu_create_texture :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUTextureCreateInfo) -> ^sdl.GPUTexture {
	if gpu_backend == .Vulkan do return vk_create_texture(device, createinfo)
	when METAL do if gpu_backend == .Metal do return mtl_create_texture(device, createinfo)
	return sdl.CreateGPUTexture(device, createinfo)
}

// A render target whose contents live only inside the pass that clears it (transient.odin):
// usage COLOR_TARGET or DEPTH_STENCIL_TARGET alone, never loaded, stored, sampled or copied.
// Memoryless on the own Metal backend, lazily allocated where the own Vulkan backend's
// device offers it (tile GPUs), a plain target otherwise and under SDL_GPU.
gpu_create_texture_transient :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUTextureCreateInfo) -> (texture: ^sdl.GPUTexture) {
	assert(createinfo.usage <= {.COLOR_TARGET, .DEPTH_STENCIL_TARGET}, "a transient texture is a render target only")
	make_it :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUTextureCreateInfo) -> ^sdl.GPUTexture {
		if gpu_backend == .Vulkan do return vk_create_texture_transient(device, createinfo)
		when METAL do if gpu_backend == .Metal do return mtl_create_texture_transient(device, createinfo)
		return sdl.CreateGPUTexture(device, createinfo)
	}
	texture = make_it(device, createinfo)
	transient_note(texture)
	return
}

// Whether transient textures save memory: a lazily allocated memory type under the own
// Vulkan backend, any Apple GPU under the own Metal one.
gpu_transient_targets_offered :: proc(device: ^sdl.GPUDevice) -> bool {
	if gpu_backend == .Vulkan do return vk_state.lazy_memory
	when METAL do if gpu_backend == .Metal do return true
	return false
}

gpu_create_transfer_buffer :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUTransferBufferCreateInfo) -> ^sdl.GPUTransferBuffer {
	if gpu_backend == .Vulkan do return vk_create_transfer_buffer(device, createinfo)
	when METAL do if gpu_backend == .Metal do return mtl_create_transfer_buffer(device, createinfo)
	return sdl.CreateGPUTransferBuffer(device, createinfo)
}

gpu_destroy_device :: proc(device: ^sdl.GPUDevice) {
	if gpu_backend == .Vulkan {
		vk_destroy_device(device)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_destroy_device(device)
		return
	}
	sdl.DestroyGPUDevice(device)
}

gpu_dispatch_compute :: proc(compute_pass: ^sdl.GPUComputePass, groupcount_x, groupcount_y, groupcount_z: sdl.Uint32) {
	if gpu_backend == .Vulkan {
		vk_dispatch_compute(compute_pass, groupcount_x, groupcount_y, groupcount_z)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_dispatch_compute(compute_pass, groupcount_x, groupcount_y, groupcount_z)
		return
	}
	sdl.DispatchGPUCompute(compute_pass, groupcount_x, groupcount_y, groupcount_z)
}

gpu_download_from_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUBufferRegion,           #by_ptr destination: sdl.GPUTransferBufferLocation) {
	if gpu_backend == .Vulkan {
		vk_download_from_buffer(copy_pass, source, destination)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_download_from_buffer(copy_pass, source, destination)
		return
	}
	sdl.DownloadFromGPUBuffer(copy_pass, source, destination)
}

gpu_download_from_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureRegion,          #by_ptr destination: sdl.GPUTextureTransferInfo) {
	transient_check_use(source.texture, "downloaded")
	if gpu_backend == .Vulkan {
		vk_download_from_texture(copy_pass, source, destination)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_download_from_texture(copy_pass, source, destination)
		return
	}
	sdl.DownloadFromGPUTexture(copy_pass, source, destination)
}

gpu_draw_indexed_primitives :: proc(render_pass: ^sdl.GPURenderPass, num_indices: sdl.Uint32,  num_instances: sdl.Uint32, first_index:  sdl.Uint32, vertex_offset: sdl.Sint32, first_instance: sdl.Uint32) {
	if gpu_backend == .Vulkan {
		vk_draw_indexed_primitives(render_pass, num_indices, num_instances, first_index, vertex_offset, first_instance)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_draw_indexed_primitives(render_pass, num_indices, num_instances, first_index, vertex_offset, first_instance)
		return
	}
	sdl.DrawGPUIndexedPrimitives(render_pass, num_indices, num_instances, first_index, vertex_offset, first_instance)
}

gpu_draw_indexed_primitives_indirect :: proc(render_pass: ^sdl.GPURenderPass, buffer: ^sdl.GPUBuffer, offset: sdl.Uint32, draw_count: sdl.Uint32) {
	if gpu_backend == .Vulkan {
		vk_draw_indexed_primitives_indirect(render_pass, buffer, offset, draw_count)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_draw_indexed_primitives_indirect(render_pass, buffer, offset, draw_count)
		return
	}
	sdl.DrawGPUIndexedPrimitivesIndirect(render_pass, buffer, offset, draw_count)
}

gpu_draw_primitives :: proc(render_pass: ^sdl.GPURenderPass, num_vertices: sdl.Uint32, num_instances: sdl.Uint32, first_vertex: sdl.Uint32, first_instance: sdl.Uint32) {
	if gpu_backend == .Vulkan {
		vk_draw_primitives(render_pass, num_vertices, num_instances, first_vertex, first_instance)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_draw_primitives(render_pass, num_vertices, num_instances, first_vertex, first_instance)
		return
	}
	sdl.DrawGPUPrimitives(render_pass, num_vertices, num_instances, first_vertex, first_instance)
}

gpu_end_compute_pass :: proc(compute_pass: ^sdl.GPUComputePass) {
	if gpu_backend == .Vulkan {
		vk_end_compute_pass(compute_pass)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_end_compute_pass(compute_pass)
		return
	}
	sdl.EndGPUComputePass(compute_pass)
}

gpu_end_copy_pass :: proc(copy_pass: ^sdl.GPUCopyPass) {
	if gpu_backend == .Vulkan {
		vk_end_copy_pass(copy_pass)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_end_copy_pass(copy_pass)
		return
	}
	sdl.EndGPUCopyPass(copy_pass)
}

gpu_end_render_pass :: proc(render_pass: ^sdl.GPURenderPass) {
	if gpu_backend == .Vulkan {
		vk_end_render_pass(render_pass)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_end_render_pass(render_pass)
		return
	}
	sdl.EndGPURenderPass(render_pass)
}

gpu_texture_supports_format :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, type: sdl.GPUTextureType, usage: sdl.GPUTextureUsageFlags) -> bool {
	if gpu_backend == .Vulkan do return vk_texture_supports_format(device, format, type, usage)
	when METAL do if gpu_backend == .Metal do return mtl_texture_supports_format(device, format, type, usage)
	return sdl.GPUTextureSupportsFormat(device, format, type, usage)
}

gpu_texture_supports_sample_count :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, sample_count: sdl.GPUSampleCount) -> bool {
	if gpu_backend == .Vulkan do return vk_texture_supports_sample_count(device, format, sample_count)
	when METAL do if gpu_backend == .Metal do return mtl_texture_supports_sample_count(device, format, sample_count)
	return sdl.GPUTextureSupportsSampleCount(device, format, sample_count)
}

gpu_generate_mipmaps_for_texture :: proc(command_buffer: ^sdl.GPUCommandBuffer, texture: ^sdl.GPUTexture) {
	transient_check_use(texture, "mipmapped")
	if gpu_backend == .Vulkan {
		vk_generate_mipmaps_for_texture(command_buffer, texture)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_generate_mipmaps_for_texture(command_buffer, texture)
		return
	}
	sdl.GenerateMipmapsForGPUTexture(command_buffer, texture)
}

gpu_get_device_driver :: proc(device: ^sdl.GPUDevice) -> cstring {
	if gpu_backend == .Vulkan do return vk_get_device_driver(device)
	when METAL do if gpu_backend == .Metal do return mtl_get_device_driver(device)
	return sdl.GetGPUDeviceDriver(device)
}

gpu_get_device_properties :: proc(device: ^sdl.GPUDevice) -> sdl.PropertiesID {
	if gpu_backend == .Vulkan do return vk_get_device_properties(device)
	when METAL do if gpu_backend == .Metal do return mtl_get_device_properties(device)
	return sdl.GetGPUDeviceProperties(device)
}

gpu_get_swapchain_texture_format :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) -> sdl.GPUTextureFormat {
	if gpu_backend == .Vulkan do return vk_get_swapchain_texture_format(device, window)
	when METAL do if gpu_backend == .Metal do return mtl_get_swapchain_texture_format(device, window)
	return sdl.GetGPUSwapchainTextureFormat(device, window)
}

gpu_map_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer, cycle: bool) -> rawptr {
	if gpu_backend == .Vulkan do return vk_map_transfer_buffer(device, transfer_buffer, cycle)
	when METAL do if gpu_backend == .Metal do return mtl_map_transfer_buffer(device, transfer_buffer, cycle)
	return sdl.MapGPUTransferBuffer(device, transfer_buffer, cycle)
}

gpu_push_compute_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: sdl.Uint32, data: rawptr, length: sdl.Uint32) {
	if gpu_backend == .Vulkan {
		vk_push_compute_uniform_data(command_buffer, slot_index, data, length)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_push_compute_uniform_data(command_buffer, slot_index, data, length)
		return
	}
	sdl.PushGPUComputeUniformData(command_buffer, slot_index, data, length)
}

gpu_push_fragment_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: sdl.Uint32, data: rawptr, length: sdl.Uint32) {
	if gpu_backend == .Vulkan {
		vk_push_fragment_uniform_data(command_buffer, slot_index, data, length)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_push_fragment_uniform_data(command_buffer, slot_index, data, length)
		return
	}
	sdl.PushGPUFragmentUniformData(command_buffer, slot_index, data, length)
}

gpu_push_vertex_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: sdl.Uint32, data: rawptr, length: sdl.Uint32) {
	if gpu_backend == .Vulkan {
		vk_push_vertex_uniform_data(command_buffer, slot_index, data, length)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_push_vertex_uniform_data(command_buffer, slot_index, data, length)
		return
	}
	sdl.PushGPUVertexUniformData(command_buffer, slot_index, data, length)
}

gpu_query_fence :: proc(device: ^sdl.GPUDevice, fence: ^sdl.GPUFence) -> bool {
	if gpu_backend == .Vulkan do return vk_query_fence(device, fence)
	when METAL do if gpu_backend == .Metal do return mtl_query_fence(device, fence)
	return sdl.QueryGPUFence(device, fence)
}

gpu_release_buffer :: proc(device: ^sdl.GPUDevice, buffer: ^sdl.GPUBuffer) {
	if gpu_backend == .Vulkan {
		vk_release_buffer(device, buffer)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_release_buffer(device, buffer)
		return
	}
	sdl.ReleaseGPUBuffer(device, buffer)
}

gpu_release_compute_pipeline :: proc(device: ^sdl.GPUDevice, compute_pipeline: ^sdl.GPUComputePipeline) {
	if gpu_backend == .Vulkan {
		vk_release_compute_pipeline(device, compute_pipeline)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_release_compute_pipeline(device, compute_pipeline)
		return
	}
	sdl.ReleaseGPUComputePipeline(device, compute_pipeline)
}

gpu_release_fence :: proc(device: ^sdl.GPUDevice, fence: ^sdl.GPUFence) {
	if gpu_backend == .Vulkan {
		vk_release_fence(device, fence)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_release_fence(device, fence)
		return
	}
	sdl.ReleaseGPUFence(device, fence)
}

gpu_release_graphics_pipeline :: proc(device: ^sdl.GPUDevice, graphics_pipeline: ^sdl.GPUGraphicsPipeline) {
	if gpu_backend == .Vulkan {
		vk_release_graphics_pipeline(device, graphics_pipeline)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_release_graphics_pipeline(device, graphics_pipeline)
		return
	}
	sdl.ReleaseGPUGraphicsPipeline(device, graphics_pipeline)
}

gpu_release_sampler :: proc(device: ^sdl.GPUDevice, sampler: ^sdl.GPUSampler) {
	if gpu_backend == .Vulkan {
		vk_release_sampler(device, sampler)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_release_sampler(device, sampler)
		return
	}
	sdl.ReleaseGPUSampler(device, sampler)
}

gpu_release_shader :: proc(device: ^sdl.GPUDevice, shader: ^sdl.GPUShader) {
	if gpu_backend == .Vulkan {
		vk_release_shader(device, shader)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_release_shader(device, shader)
		return
	}
	sdl.ReleaseGPUShader(device, shader)
}

gpu_release_texture :: proc(device: ^sdl.GPUDevice, texture: ^sdl.GPUTexture) {
	transient_forget(texture)
	if gpu_backend == .Vulkan {
		vk_release_texture(device, texture)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_release_texture(device, texture)
		return
	}
	sdl.ReleaseGPUTexture(device, texture)
}

gpu_release_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer) {
	if gpu_backend == .Vulkan {
		vk_release_transfer_buffer(device, transfer_buffer)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_release_transfer_buffer(device, transfer_buffer)
		return
	}
	sdl.ReleaseGPUTransferBuffer(device, transfer_buffer)
}

gpu_release_window_from_device :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) {
	if gpu_backend == .Vulkan {
		vk_release_window(device, window)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_release_window(device, window)
		return
	}
	sdl.ReleaseWindowFromGPUDevice(device, window)
}

gpu_set_scissor :: proc(render_pass: ^sdl.GPURenderPass, #by_ptr scissor: sdl.Rect) {
	if gpu_backend == .Vulkan {
		vk_set_scissor(render_pass, scissor)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_set_scissor(render_pass, scissor)
		return
	}
	sdl.SetGPUScissor(render_pass, scissor)
}

gpu_push_debug_group :: proc(command_buffer: ^sdl.GPUCommandBuffer, name: cstring) {
	if gpu_backend == .Vulkan {
		vk_push_debug_group(command_buffer, name)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_push_debug_group(command_buffer, name)
		return
	}
	sdl.PushGPUDebugGroup(command_buffer, name)
}

gpu_pop_debug_group :: proc(command_buffer: ^sdl.GPUCommandBuffer) {
	if gpu_backend == .Vulkan {
		vk_pop_debug_group(command_buffer)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_pop_debug_group(command_buffer)
		return
	}
	sdl.PopGPUDebugGroup(command_buffer)
}

gpu_set_buffer_name :: proc(device: ^sdl.GPUDevice, buffer: ^sdl.GPUBuffer, text: cstring) {
	if gpu_backend == .Vulkan {
		vk_set_buffer_name(device, buffer, text)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_set_buffer_name(device, buffer, text)
		return
	}
	sdl.SetGPUBufferName(device, buffer, text)
}

gpu_set_texture_name :: proc(device: ^sdl.GPUDevice, texture: ^sdl.GPUTexture, text: cstring) {
	if gpu_backend == .Vulkan {
		vk_set_texture_name(device, texture, text)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_set_texture_name(device, texture, text)
		return
	}
	sdl.SetGPUTextureName(device, texture, text)
}

gpu_set_allowed_frames_in_flight :: proc(device: ^sdl.GPUDevice, allowed_frames_in_flight: u32) -> bool {
	if gpu_backend == .Vulkan do return vk_set_allowed_frames_in_flight(device, allowed_frames_in_flight)
	when METAL do if gpu_backend == .Metal do return mtl_set_allowed_frames_in_flight(device, allowed_frames_in_flight)
	return sdl.SetGPUAllowedFramesInFlight(device, allowed_frames_in_flight)
}

// SDL_GPU has no call telling when a frame reached the screen, so only the own Vulkan and
// Metal backends answer these; SDL_GPU learns nothing (Gpu_Caps.present_timing).
gpu_present_timing :: proc(device: ^sdl.GPUDevice) -> Present_Timing {
	if gpu_backend == .Vulkan do return vk_state.present_timing
	when METAL do if gpu_backend == .Metal do return .Presented_Handler
	return .None
}

gpu_present_input :: proc(window: ^sdl.Window, input_ns: u64) {
	if gpu_backend == .Vulkan do vk_present_input(window, input_ns)
	when METAL do if gpu_backend == .Metal do mtl_present_input(window, input_ns)
}

gpu_present_times :: proc(window: ^sdl.Window, out: []Present_Time) -> int {
	if gpu_backend == .Vulkan do return vk_present_times(window, out)
	when METAL do if gpu_backend == .Metal do return mtl_present_times(window, out)
	return 0
}

// Frames presented that never reached the screen, since the device was made; `known` false
// where the backend cannot tell (only the own Metal backend's presented handlers can).
gpu_frames_dropped :: proc() -> (dropped: u64, known: bool) {
	when METAL do if gpu_backend == .Metal do return mtl_frames_dropped(), true
	return 0, false
}

// Whether gpu_create_buffer_mapped makes buffers: the own Vulkan backend with a shared
// memory type (vk_pick_shared_type), the own Metal backend on unified memory.
gpu_shared_buffers_offered :: proc(device: ^sdl.GPUDevice) -> bool {
	if gpu_backend == .Vulkan do return vk_state.shared_buffers
	when METAL do if gpu_backend == .Metal do return mtl_shared_buffers_offered()
	return false
}

// A device buffer whose `info.size` bytes the CPU writes through `mapped` before anything
// uses it, then ends with gpu_buffer_filled; nil, nil where the backend cannot, and the
// caller uploads into a plain buffer instead. SDL_GPU has no such buffers.
gpu_create_buffer_mapped :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUBufferCreateInfo, accel_input := false) -> (buffer: ^sdl.GPUBuffer, mapped: rawptr) {
	if gpu_backend == .Vulkan do return vk_create_buffer_mapped(device, info, accel_input)
	when METAL do if gpu_backend == .Metal do return mtl_create_buffer_mapped(device, info)
	return nil, nil
}

// Ends the fill of a gpu_create_buffer_mapped buffer; the mapped pointer is invalid after.
gpu_buffer_filled :: proc(device: ^sdl.GPUDevice, buffer: ^sdl.GPUBuffer) {
	if gpu_backend == .Vulkan do vk_buffer_filled(device, buffer)
}

// The compute kernels' subgroup width (0 when unknown) and whether 64-bit buffer atomics
// work; SDL_GPU tells neither.
gpu_compute_features :: proc(device: ^sdl.GPUDevice) -> (subgroup_size: u32, int64_atomics: bool) {
	if gpu_backend == .Vulkan do return vk_state.subgroup_size, vk_state.int64_atomics
	when METAL do if gpu_backend == .Metal do return mtl_compute_features()
	return 0, false
}

// GPU timestamps: SDL_GPU has no query API yet (its draft is libsdl-org/SDL#15651), and
// Apple GPUs sample counters only where a pass begins or ends, so the own Metal backend
// would time passes, not the debug groups these timestamps bracket.
gpu_timestamps_offered :: proc(device: ^sdl.GPUDevice) -> bool {
	return gpu_backend == .Vulkan && vk_state.timing.slots[0].pool != 0
}

gpu_write_timestamp :: proc(command_buffer: ^sdl.GPUCommandBuffer, tag: u8) {
	if gpu_backend == .Vulkan do vk_write_timestamp((^Vk_Cmd)(command_buffer), tag)
}

gpu_timestamps_frame :: proc(device: ^sdl.GPUDevice, out: []Gpu_Timestamp) -> int {
	if gpu_backend == .Vulkan do return vk_timestamps_frame(out)
	return 0
}

// Pre-rotation likewise: SDL_GPU leaves the compositor to turn its images, and Apple's
// compositor turns Metal's at no cost, so only the own Vulkan backend's can be turned.
gpu_swapchain_turns :: proc(window: ^sdl.Window) -> int {
	if gpu_backend == .Vulkan do return vk_swapchain_turns(window)
	return 0
}

gpu_set_swapchain_parameters :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window, swapchain_composition: sdl.GPUSwapchainComposition, present_mode: sdl.GPUPresentMode) -> bool {
	if gpu_backend == .Vulkan do return vk_set_swapchain_parameters(device, window, swapchain_composition, present_mode)
	when METAL do if gpu_backend == .Metal do return mtl_set_swapchain_parameters(device, window, swapchain_composition, present_mode)
	return sdl.SetGPUSwapchainParameters(device, window, swapchain_composition, present_mode)
}

gpu_submit_command_buffer :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	if gpu_backend == .Vulkan do return vk_submit_command_buffer(command_buffer)
	when METAL do if gpu_backend == .Metal do return mtl_submit_command_buffer(command_buffer)
	return sdl.SubmitGPUCommandBuffer(command_buffer)
}

gpu_submit_command_buffer_and_acquire_fence :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> ^sdl.GPUFence {
	if gpu_backend == .Vulkan do return vk_submit_command_buffer_and_acquire_fence(command_buffer)
	when METAL do if gpu_backend == .Metal do return mtl_submit_command_buffer_and_acquire_fence(command_buffer)
	return sdl.SubmitGPUCommandBufferAndAcquireFence(command_buffer)
}

gpu_unmap_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer) {
	if gpu_backend == .Vulkan {
		vk_unmap_transfer_buffer(device, transfer_buffer)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_unmap_transfer_buffer(device, transfer_buffer)
		return
	}
	sdl.UnmapGPUTransferBuffer(device, transfer_buffer)
}

gpu_upload_to_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTransferBufferLocation, #by_ptr destination: sdl.GPUBufferRegion, cycle: bool) {
	if gpu_backend == .Vulkan {
		vk_upload_to_buffer(copy_pass, source, destination, cycle)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_upload_to_buffer(copy_pass, source, destination, cycle)
		return
	}
	sdl.UploadToGPUBuffer(copy_pass, source, destination, cycle)
}

gpu_upload_to_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureTransferInfo,    #by_ptr destination: sdl.GPUTextureRegion, cycle: bool) {
	transient_check_use(destination.texture, "uploaded to")
	if gpu_backend == .Vulkan {
		vk_upload_to_texture(copy_pass, source, destination, cycle)
		return
	}
	when METAL do if gpu_backend == .Metal {
		mtl_upload_to_texture(copy_pass, source, destination, cycle)
		return
	}
	sdl.UploadToGPUTexture(copy_pass, source, destination, cycle)
}

gpu_wait_and_acquire_swapchain_texture :: proc(command_buffer: ^sdl.GPUCommandBuffer, window: ^sdl.Window, swapchain_texture: ^^sdl.GPUTexture, swapchain_texture_width, swapchain_texture_height: ^sdl.Uint32) -> bool {
	if gpu_backend == .Vulkan do return vk_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, true)
	when METAL do if gpu_backend == .Metal do return mtl_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, true)
	return sdl.WaitAndAcquireGPUSwapchainTexture(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height)
}

gpu_wait_for_fences :: proc(device: ^sdl.GPUDevice, wait_all: bool, fences: [^]^sdl.GPUFence, num_fences: sdl.Uint32) -> bool {
	if gpu_backend == .Vulkan do return vk_wait_for_fences(device, wait_all, fences, num_fences)
	when METAL do if gpu_backend == .Metal do return mtl_wait_for_fences(device, wait_all, fences, num_fences)
	return sdl.WaitForGPUFences(device, wait_all, fences, num_fences)
}

gpu_wait_for_idle :: proc(device: ^sdl.GPUDevice) -> bool {
	if gpu_backend == .Vulkan do return vk_wait_for_idle(device)
	when METAL do if gpu_backend == .Metal do return mtl_wait_for_idle(device)
	return sdl.WaitForGPUIdle(device)
}

gpu_window_supports_present_mode :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window, present_mode: sdl.GPUPresentMode) -> bool {
	if gpu_backend == .Vulkan do return vk_window_supports_present_mode(device, window, present_mode)
	when METAL do if gpu_backend == .Metal do return mtl_window_supports_present_mode(device, window, present_mode)
	return sdl.WindowSupportsGPUPresentMode(device, window, present_mode)
}
