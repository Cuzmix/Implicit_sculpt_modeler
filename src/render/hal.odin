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
	if gpu_backend == .Vulkan do return vk_begin_render_pass(command_buffer, color_target_infos, num_color_targets, depth_stencil_target_info)
	when METAL do if gpu_backend == .Metal do return mtl_begin_render_pass(command_buffer, color_target_infos, num_color_targets, depth_stencil_target_info)
	return sdl.BeginGPURenderPass(command_buffer, color_target_infos, num_color_targets, depth_stencil_target_info)
}

gpu_bind_compute_pipeline :: proc(compute_pass: ^sdl.GPUComputePass, compute_pipeline: ^sdl.GPUComputePipeline) {
	if gpu_backend == .Vulkan {
		vk_bind_compute_pipeline(compute_pass, compute_pipeline)
		return
	}
	// The Metal backend makes no compute pipelines, so no compute pass is ever open.
	when METAL do if gpu_backend == .Metal do return
	sdl.BindGPUComputePipeline(compute_pass, compute_pipeline)
}

gpu_bind_compute_samplers :: proc(compute_pass: ^sdl.GPUComputePass, first_slot: sdl.Uint32, texture_sampler_bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: sdl.Uint32) {
	if gpu_backend == .Vulkan {
		vk_bind_compute_samplers(compute_pass, first_slot, texture_sampler_bindings, num_bindings)
		return
	}
	// The Metal backend makes no compute pipelines, so no compute pass is ever open.
	when METAL do if gpu_backend == .Metal do return
	sdl.BindGPUComputeSamplers(compute_pass, first_slot, texture_sampler_bindings, num_bindings)
}

gpu_bind_compute_storage_buffers :: proc(compute_pass: ^sdl.GPUComputePass, first_slot: sdl.Uint32, storage_buffers: [^]^sdl.GPUBuffer, num_bindings: sdl.Uint32) {
	if gpu_backend == .Vulkan {
		vk_bind_compute_storage_buffers(compute_pass, first_slot, storage_buffers, num_bindings)
		return
	}
	// The Metal backend makes no compute pipelines, so no compute pass is ever open.
	when METAL do if gpu_backend == .Metal do return
	sdl.BindGPUComputeStorageBuffers(compute_pass, first_slot, storage_buffers, num_bindings)
}

gpu_bind_fragment_samplers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: sdl.Uint32, texture_sampler_bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: sdl.Uint32) {
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

gpu_create_buffer :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUBufferCreateInfo) -> ^sdl.GPUBuffer {
	if gpu_backend == .Vulkan do return vk_create_buffer(device, createinfo)
	when METAL do if gpu_backend == .Metal do return mtl_create_buffer(device, createinfo)
	return sdl.CreateGPUBuffer(device, createinfo)
}

gpu_create_compute_pipeline :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUComputePipelineCreateInfo) -> ^sdl.GPUComputePipeline {
	if gpu_backend == .Vulkan do return vk_create_compute_pipeline(device, createinfo)
	when METAL do if gpu_backend == .Metal do return mtl_create_compute_pipeline(device, createinfo)
	return sdl.CreateGPUComputePipeline(device, createinfo)
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
	// The Metal backend makes no compute pipelines, so no compute pass is ever open.
	when METAL do if gpu_backend == .Metal do return
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
	// The Metal backend makes no compute pipelines, so no compute pass is ever open.
	when METAL do if gpu_backend == .Metal do return
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
	// The Metal backend makes no compute pipelines, so no compute pass is ever open.
	when METAL do if gpu_backend == .Metal do return
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
