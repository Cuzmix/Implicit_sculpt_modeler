package render

import sdl "vendor:sdl3"

// The GPU seam: every SDL_GPU call render makes goes through one of these procs, named
// after SDL's (sdl.CreateGPUTexture is gpu_create_texture) and taking its arguments, so
// a second backend (Vulkan, notes/vulkan/backend-design.md) can answer them instead.
// The handles stay SDL's types: opaque pointers render only passes back to these procs,
// never dereferences, which a backend may point at objects of its own. Nothing else in
// render calls an sdl.*GPU* proc; scripts/boundary_check.py enforces it.

gpu_acquire_command_buffer :: proc(device: ^sdl.GPUDevice) -> ^sdl.GPUCommandBuffer {
	return sdl.AcquireGPUCommandBuffer(device)
}

gpu_acquire_swapchain_texture :: proc(command_buffer: ^sdl.GPUCommandBuffer, window: ^sdl.Window, swapchain_texture: ^^sdl.GPUTexture, swapchain_texture_width, swapchain_texture_height: ^sdl.Uint32) -> bool {
	return sdl.AcquireGPUSwapchainTexture(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height)
}

gpu_begin_compute_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer, storage_texture_bindings: [^]sdl.GPUStorageTextureReadWriteBinding, num_storage_texture_bindings: sdl.Uint32, storage_buffer_bindings: [^]sdl.GPUStorageBufferReadWriteBinding, num_storage_buffer_bindings: sdl.Uint32) -> ^sdl.GPUComputePass {
	return sdl.BeginGPUComputePass(command_buffer, storage_texture_bindings, num_storage_texture_bindings, storage_buffer_bindings, num_storage_buffer_bindings)
}

gpu_begin_copy_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> ^sdl.GPUCopyPass {
	return sdl.BeginGPUCopyPass(command_buffer)
}

gpu_begin_render_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer, color_target_infos: [^]sdl.GPUColorTargetInfo, num_color_targets: sdl.Uint32, depth_stencil_target_info: Maybe(^sdl.GPUDepthStencilTargetInfo)) -> ^sdl.GPURenderPass {
	return sdl.BeginGPURenderPass(command_buffer, color_target_infos, num_color_targets, depth_stencil_target_info)
}

gpu_bind_compute_pipeline :: proc(compute_pass: ^sdl.GPUComputePass, compute_pipeline: ^sdl.GPUComputePipeline) {
	sdl.BindGPUComputePipeline(compute_pass, compute_pipeline)
}

gpu_bind_compute_samplers :: proc(compute_pass: ^sdl.GPUComputePass, first_slot: sdl.Uint32, texture_sampler_bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: sdl.Uint32) {
	sdl.BindGPUComputeSamplers(compute_pass, first_slot, texture_sampler_bindings, num_bindings)
}

gpu_bind_compute_storage_buffers :: proc(compute_pass: ^sdl.GPUComputePass, first_slot: sdl.Uint32, storage_buffers: [^]^sdl.GPUBuffer, num_bindings: sdl.Uint32) {
	sdl.BindGPUComputeStorageBuffers(compute_pass, first_slot, storage_buffers, num_bindings)
}

gpu_bind_fragment_samplers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: sdl.Uint32, texture_sampler_bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: sdl.Uint32) {
	sdl.BindGPUFragmentSamplers(render_pass, first_slot, texture_sampler_bindings, num_bindings)
}

gpu_bind_graphics_pipeline :: proc(render_pass: ^sdl.GPURenderPass, graphics_pipeline: ^sdl.GPUGraphicsPipeline) {
	sdl.BindGPUGraphicsPipeline(render_pass, graphics_pipeline)
}

gpu_bind_index_buffer :: proc(render_pass: ^sdl.GPURenderPass, #by_ptr binding: sdl.GPUBufferBinding, index_element_size: sdl.GPUIndexElementSize) {
	sdl.BindGPUIndexBuffer(render_pass, binding, index_element_size)
}

gpu_bind_vertex_buffers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: sdl.Uint32, bindings: [^]sdl.GPUBufferBinding, num_bindings: sdl.Uint32) {
	sdl.BindGPUVertexBuffers(render_pass, first_slot, bindings, num_bindings)
}

gpu_bind_vertex_storage_buffers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: sdl.Uint32, storage_buffers: [^]^sdl.GPUBuffer, num_bindings: sdl.Uint32) {
	sdl.BindGPUVertexStorageBuffers(render_pass, first_slot, storage_buffers, num_bindings)
}

gpu_cancel_command_buffer :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	return sdl.CancelGPUCommandBuffer(command_buffer)
}

gpu_claim_window_for_device :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) -> bool {
	return sdl.ClaimWindowForGPUDevice(device, window)
}

gpu_copy_buffer_to_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUBufferLocation,         #by_ptr destination: sdl.GPUBufferLocation, size: sdl.Uint32, cycle: bool) {
	sdl.CopyGPUBufferToBuffer(copy_pass, source, destination, size, cycle)
}

gpu_copy_texture_to_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureLocation,        #by_ptr destination: sdl.GPUTextureLocation, w, h, d: sdl.Uint32, cycle: bool) {
	sdl.CopyGPUTextureToTexture(copy_pass, source, destination, w, h, d, cycle)
}

gpu_create_buffer :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUBufferCreateInfo) -> ^sdl.GPUBuffer {
	return sdl.CreateGPUBuffer(device, createinfo)
}

gpu_create_compute_pipeline :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUComputePipelineCreateInfo) -> ^sdl.GPUComputePipeline {
	return sdl.CreateGPUComputePipeline(device, createinfo)
}

gpu_create_device :: proc(format_flags: sdl.GPUShaderFormat, debug_mode: bool, name: cstring) -> ^sdl.GPUDevice {
	return sdl.CreateGPUDevice(format_flags, debug_mode, name)
}

gpu_create_device_with_properties :: proc(props: sdl.PropertiesID) -> ^sdl.GPUDevice {
	return sdl.CreateGPUDeviceWithProperties(props)
}

gpu_create_graphics_pipeline :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUGraphicsPipelineCreateInfo) -> ^sdl.GPUGraphicsPipeline {
	return sdl.CreateGPUGraphicsPipeline(device, createinfo)
}

gpu_create_sampler :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUSamplerCreateInfo) -> ^sdl.GPUSampler {
	return sdl.CreateGPUSampler(device, createinfo)
}

gpu_create_shader :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUShaderCreateInfo) -> ^sdl.GPUShader {
	return sdl.CreateGPUShader(device, createinfo)
}

gpu_create_texture :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUTextureCreateInfo) -> ^sdl.GPUTexture {
	return sdl.CreateGPUTexture(device, createinfo)
}

gpu_create_transfer_buffer :: proc(device: ^sdl.GPUDevice, #by_ptr createinfo: sdl.GPUTransferBufferCreateInfo) -> ^sdl.GPUTransferBuffer {
	return sdl.CreateGPUTransferBuffer(device, createinfo)
}

gpu_destroy_device :: proc(device: ^sdl.GPUDevice) {
	sdl.DestroyGPUDevice(device)
}

gpu_dispatch_compute :: proc(compute_pass: ^sdl.GPUComputePass, groupcount_x, groupcount_y, groupcount_z: sdl.Uint32) {
	sdl.DispatchGPUCompute(compute_pass, groupcount_x, groupcount_y, groupcount_z)
}

gpu_download_from_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUBufferRegion,           #by_ptr destination: sdl.GPUTransferBufferLocation) {
	sdl.DownloadFromGPUBuffer(copy_pass, source, destination)
}

gpu_download_from_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureRegion,          #by_ptr destination: sdl.GPUTextureTransferInfo) {
	sdl.DownloadFromGPUTexture(copy_pass, source, destination)
}

gpu_draw_indexed_primitives :: proc(render_pass: ^sdl.GPURenderPass, num_indices: sdl.Uint32,  num_instances: sdl.Uint32, first_index:  sdl.Uint32, vertex_offset: sdl.Sint32, first_instance: sdl.Uint32) {
	sdl.DrawGPUIndexedPrimitives(render_pass, num_indices, num_instances, first_index, vertex_offset, first_instance)
}

gpu_draw_indexed_primitives_indirect :: proc(render_pass: ^sdl.GPURenderPass, buffer: ^sdl.GPUBuffer, offset: sdl.Uint32, draw_count: sdl.Uint32) {
	sdl.DrawGPUIndexedPrimitivesIndirect(render_pass, buffer, offset, draw_count)
}

gpu_draw_primitives :: proc(render_pass: ^sdl.GPURenderPass, num_vertices: sdl.Uint32, num_instances: sdl.Uint32, first_vertex: sdl.Uint32, first_instance: sdl.Uint32) {
	sdl.DrawGPUPrimitives(render_pass, num_vertices, num_instances, first_vertex, first_instance)
}

gpu_end_compute_pass :: proc(compute_pass: ^sdl.GPUComputePass) {
	sdl.EndGPUComputePass(compute_pass)
}

gpu_end_copy_pass :: proc(copy_pass: ^sdl.GPUCopyPass) {
	sdl.EndGPUCopyPass(copy_pass)
}

gpu_end_render_pass :: proc(render_pass: ^sdl.GPURenderPass) {
	sdl.EndGPURenderPass(render_pass)
}

gpu_texture_supports_format :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, type: sdl.GPUTextureType, usage: sdl.GPUTextureUsageFlags) -> bool {
	return sdl.GPUTextureSupportsFormat(device, format, type, usage)
}

gpu_texture_supports_sample_count :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, sample_count: sdl.GPUSampleCount) -> bool {
	return sdl.GPUTextureSupportsSampleCount(device, format, sample_count)
}

gpu_generate_mipmaps_for_texture :: proc(command_buffer: ^sdl.GPUCommandBuffer, texture: ^sdl.GPUTexture) {
	sdl.GenerateMipmapsForGPUTexture(command_buffer, texture)
}

gpu_get_device_driver :: proc(device: ^sdl.GPUDevice) -> cstring {
	return sdl.GetGPUDeviceDriver(device)
}

gpu_get_device_properties :: proc(device: ^sdl.GPUDevice) -> sdl.PropertiesID {
	return sdl.GetGPUDeviceProperties(device)
}

gpu_get_swapchain_texture_format :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) -> sdl.GPUTextureFormat {
	return sdl.GetGPUSwapchainTextureFormat(device, window)
}

gpu_map_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer, cycle: bool) -> rawptr {
	return sdl.MapGPUTransferBuffer(device, transfer_buffer, cycle)
}

gpu_push_compute_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: sdl.Uint32, data: rawptr, length: sdl.Uint32) {
	sdl.PushGPUComputeUniformData(command_buffer, slot_index, data, length)
}

gpu_push_fragment_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: sdl.Uint32, data: rawptr, length: sdl.Uint32) {
	sdl.PushGPUFragmentUniformData(command_buffer, slot_index, data, length)
}

gpu_push_vertex_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: sdl.Uint32, data: rawptr, length: sdl.Uint32) {
	sdl.PushGPUVertexUniformData(command_buffer, slot_index, data, length)
}

gpu_query_fence :: proc(device: ^sdl.GPUDevice, fence: ^sdl.GPUFence) -> bool {
	return sdl.QueryGPUFence(device, fence)
}

gpu_release_buffer :: proc(device: ^sdl.GPUDevice, buffer: ^sdl.GPUBuffer) {
	sdl.ReleaseGPUBuffer(device, buffer)
}

gpu_release_compute_pipeline :: proc(device: ^sdl.GPUDevice, compute_pipeline: ^sdl.GPUComputePipeline) {
	sdl.ReleaseGPUComputePipeline(device, compute_pipeline)
}

gpu_release_fence :: proc(device: ^sdl.GPUDevice, fence: ^sdl.GPUFence) {
	sdl.ReleaseGPUFence(device, fence)
}

gpu_release_graphics_pipeline :: proc(device: ^sdl.GPUDevice, graphics_pipeline: ^sdl.GPUGraphicsPipeline) {
	sdl.ReleaseGPUGraphicsPipeline(device, graphics_pipeline)
}

gpu_release_sampler :: proc(device: ^sdl.GPUDevice, sampler: ^sdl.GPUSampler) {
	sdl.ReleaseGPUSampler(device, sampler)
}

gpu_release_shader :: proc(device: ^sdl.GPUDevice, shader: ^sdl.GPUShader) {
	sdl.ReleaseGPUShader(device, shader)
}

gpu_release_texture :: proc(device: ^sdl.GPUDevice, texture: ^sdl.GPUTexture) {
	sdl.ReleaseGPUTexture(device, texture)
}

gpu_release_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer) {
	sdl.ReleaseGPUTransferBuffer(device, transfer_buffer)
}

gpu_release_window_from_device :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) {
	sdl.ReleaseWindowFromGPUDevice(device, window)
}

gpu_set_scissor :: proc(render_pass: ^sdl.GPURenderPass, #by_ptr scissor: sdl.Rect) {
	sdl.SetGPUScissor(render_pass, scissor)
}

gpu_set_swapchain_parameters :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window, swapchain_composition: sdl.GPUSwapchainComposition, present_mode: sdl.GPUPresentMode) -> bool {
	return sdl.SetGPUSwapchainParameters(device, window, swapchain_composition, present_mode)
}

gpu_submit_command_buffer :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	return sdl.SubmitGPUCommandBuffer(command_buffer)
}

gpu_submit_command_buffer_and_acquire_fence :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> ^sdl.GPUFence {
	return sdl.SubmitGPUCommandBufferAndAcquireFence(command_buffer)
}

gpu_unmap_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer) {
	sdl.UnmapGPUTransferBuffer(device, transfer_buffer)
}

gpu_upload_to_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTransferBufferLocation, #by_ptr destination: sdl.GPUBufferRegion, cycle: bool) {
	sdl.UploadToGPUBuffer(copy_pass, source, destination, cycle)
}

gpu_upload_to_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureTransferInfo,    #by_ptr destination: sdl.GPUTextureRegion, cycle: bool) {
	sdl.UploadToGPUTexture(copy_pass, source, destination, cycle)
}

gpu_wait_and_acquire_swapchain_texture :: proc(command_buffer: ^sdl.GPUCommandBuffer, window: ^sdl.Window, swapchain_texture: ^^sdl.GPUTexture, swapchain_texture_width, swapchain_texture_height: ^sdl.Uint32) -> bool {
	return sdl.WaitAndAcquireGPUSwapchainTexture(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height)
}

gpu_wait_for_fences :: proc(device: ^sdl.GPUDevice, wait_all: bool, fences: [^]^sdl.GPUFence, num_fences: sdl.Uint32) -> bool {
	return sdl.WaitForGPUFences(device, wait_all, fences, num_fences)
}

gpu_wait_for_idle :: proc(device: ^sdl.GPUDevice) -> bool {
	return sdl.WaitForGPUIdle(device)
}

gpu_window_supports_present_mode :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window, present_mode: sdl.GPUPresentMode) -> bool {
	return sdl.WindowSupportsGPUPresentMode(device, window, present_mode)
}
