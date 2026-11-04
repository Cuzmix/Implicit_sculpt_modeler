package gpu

@(require) import "core:log" // used only by the Metal and WebGPU branches

import "core:time"
import sdl "vendor:sdl3"

// The GPU seam: every GPU call render makes goes through one of these procs, answered by
// the own Metal backend (mtl_*.odin) on Apple's platforms, the WebGPU one (wgpu_*.odin) in a
// browser and the own Vulkan backend (vk_*.odin) everywhere else. Their names still follow
// SDL_GPU's procs without the prefix (sdl.CreateGPUTexture was gpu.create_texture), though
// SDL_GPU itself no longer draws; the GPU abstraction's own API replaces them step by step
// (notes/gpu-own-model/design.md). There is one device, made by create_device and held by
// the backend, so no proc takes one. They speak the package's own types (types.odin): its
// formats, states and descriptions, and opaque handles render only passes back to these
// procs, which each backend points at objects of its own. A proc that fails returns nil or
// false and says why through last_error (errors.odin). Render names no SDL_GPU type and
// nothing calls an sdl.*GPU* proc; scripts/boundary_check.py enforces both. Every proc that
// returns something is require_results, so no failure goes unread.

// The Metal backend exists only where Metal does; elsewhere its branches are not compiled,
// and on Apple's platforms the Vulkan ones are not.
METAL :: ODIN_OS == .Darwin
// The WebGPU backend (wgpu_*.odin) answers in a browser, the web version's only GPU API;
// Vulkan answers everywhere else.
WEBGPU :: ODIN_OS == .JS
VULKAN :: !METAL && !WEBGPU

@(require_results)
acquire_command_buffer :: proc() -> (cmd: Cmd) {
	when METAL do cmd = mtl_acquire_command_buffer()
	else when WEBGPU do cmd = wgpu_acquire_command_buffer()
	else do cmd = vk_acquire_command_buffer()
	count_acquire(cmd)
	return
}

// A command buffer whose compute passes run on the compute queue (Gpu_Caps.async_compute),
// submitted with submit, whose ticket is then on the compute queue; nil (with last_error)
// where there is none. It
// holds compute passes only.
@(require_results)
acquire_compute_command_buffer :: proc() -> Cmd {
	when METAL {
		fail(.Unsupported, "no compute queue under this backend")
		return nil
	} else when WEBGPU {
		fail(.Unsupported, "no compute queue under WebGPU")
		return nil
	} else {
		cmd := vk_acquire_compute_command_buffer()
		count_acquire(cmd)
		return cmd
	}
}

// Makes a graphics command buffer wait, at every stage, for the compute submissions up
// to `ticket` before it runs, so it sees what they wrote. Waiting on a ticket that is
// already done stalls nothing.
wait_on :: proc(command_buffer: Cmd, ticket: Ticket) {
	when VULKAN {
		vk_wait_on(command_buffer, ticket)
	}
}

@(require_results)
async_compute_offered :: proc() -> Async_Compute {
	when METAL do return .Off
	else when WEBGPU do return .Off
	else do return vk_state.async_compute
}

@(require_results)
acquire_swapchain_texture :: proc(command_buffer: Cmd, window: ^sdl.Window, swapchain_texture: ^Texture, swapchain_texture_width, swapchain_texture_height: ^u32) -> bool {
	start := time.tick_now()
	defer count_pause(command_buffer, time.tick_since(start))
	when METAL do return mtl_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, false)
	else when WEBGPU do return wgpu_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, false)
	else do return vk_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, false)
}

@(require_results)
begin_compute_pass :: proc(command_buffer: Cmd, storage_texture_bindings: [^]Storage_Texture_Binding, num_storage_texture_bindings: u32, storage_buffer_bindings: [^]Storage_Buffer_Binding, num_storage_buffer_bindings: u32) -> Compute_Pass {
	staging_flush(command_buffer)
	when METAL do return mtl_begin_compute_pass(command_buffer, storage_texture_bindings, num_storage_texture_bindings, storage_buffer_bindings, num_storage_buffer_bindings)
	else when WEBGPU do return wgpu_begin_compute_pass(command_buffer, storage_texture_bindings, num_storage_texture_bindings, storage_buffer_bindings, num_storage_buffer_bindings)
	else do return vk_begin_compute_pass(command_buffer, storage_texture_bindings, num_storage_texture_bindings, storage_buffer_bindings, num_storage_buffer_bindings)
}

@(require_results)
begin_copy_pass :: proc(command_buffer: Cmd) -> Copy_Pass {
	staging_flush(command_buffer)
	return begin_copy_pass_raw(command_buffer)
}

// A copy pass with nothing staged recorded first: staging_flush's own.
@(private, require_results)
begin_copy_pass_raw :: proc(command_buffer: Cmd) -> Copy_Pass {
	when METAL do return mtl_begin_copy_pass(command_buffer)
	else when WEBGPU do return wgpu_begin_copy_pass(command_buffer)
	else do return vk_begin_copy_pass(command_buffer)
}

@(require_results)
begin_render_pass :: proc(command_buffer: Cmd, color_target_infos: [^]Color_Target, num_color_targets: u32, depth_stencil_target_info: Maybe(^Depth_Target)) -> Render_Pass {
	transient_check_pass(color_target_infos, num_color_targets, depth_stencil_target_info)
	staging_flush(command_buffer)
	when METAL do return mtl_begin_render_pass(command_buffer, color_target_infos, num_color_targets, depth_stencil_target_info)
	else when WEBGPU do return wgpu_begin_render_pass(command_buffer, color_target_infos, num_color_targets, depth_stencil_target_info)
	else do return vk_begin_render_pass(command_buffer, color_target_infos, num_color_targets, depth_stencil_target_info)
}

bind_compute_pipeline :: proc(compute_pass: Compute_Pass, compute_pipeline: Compute_Pipeline) {
	when METAL do mtl_bind_compute_pipeline(compute_pass, compute_pipeline)
	else when WEBGPU do wgpu_bind_compute_pipeline(compute_pass, compute_pipeline)
	else do vk_bind_compute_pipeline(compute_pass, compute_pipeline)
}

bind_compute_samplers :: proc(compute_pass: Compute_Pass, first_slot: u32, texture_sampler_bindings: [^]Texture_Sampler_Binding, num_bindings: u32) {
	for b in texture_sampler_bindings[:num_bindings] do transient_check_use(b.texture, "sampled")
	when METAL do mtl_bind_compute_samplers(compute_pass, first_slot, texture_sampler_bindings, num_bindings)
	else when WEBGPU do wgpu_bind_compute_samplers(compute_pass, first_slot, texture_sampler_bindings, num_bindings)
	else do vk_bind_compute_samplers(compute_pass, first_slot, texture_sampler_bindings, num_bindings)
}

// The textures, in order, of the array a create_compute_pipeline_array kernel reads; at
// most the capacity it was made with. Only the own Vulkan backend makes such kernels.
bind_compute_texture_array :: proc(compute_pass: Compute_Pass, bindings: []Texture_Sampler_Binding) {
	for b in bindings do transient_check_use(b.texture, "sampled")
	when VULKAN {
		vk_bind_compute_texture_array(compute_pass, bindings)
	}
}

bind_compute_storage_buffers :: proc(compute_pass: Compute_Pass, first_slot: u32, storage_buffers: [^]Buffer, num_bindings: u32) {
	when METAL do mtl_bind_compute_storage_buffers(compute_pass, first_slot, storage_buffers, num_bindings)
	else when WEBGPU do wgpu_bind_compute_storage_buffers(compute_pass, first_slot, storage_buffers, num_bindings)
	else do vk_bind_compute_storage_buffers(compute_pass, first_slot, storage_buffers, num_bindings)
}

bind_fragment_samplers :: proc(render_pass: Render_Pass, first_slot: u32, texture_sampler_bindings: [^]Texture_Sampler_Binding, num_bindings: u32) {
	for b in texture_sampler_bindings[:num_bindings] do transient_check_use(b.texture, "sampled")
	when METAL do mtl_bind_fragment_samplers(render_pass, first_slot, texture_sampler_bindings, num_bindings)
	else when WEBGPU do wgpu_bind_fragment_samplers(render_pass, first_slot, texture_sampler_bindings, num_bindings)
	else do vk_bind_fragment_samplers(render_pass, first_slot, texture_sampler_bindings, num_bindings)
}

bind_graphics_pipeline :: proc(render_pass: Render_Pass, graphics_pipeline: Graphics_Pipeline) {
	when METAL do mtl_bind_graphics_pipeline(render_pass, graphics_pipeline)
	else when WEBGPU do wgpu_bind_graphics_pipeline(render_pass, graphics_pipeline)
	else do vk_bind_graphics_pipeline(render_pass, graphics_pipeline)
}

bind_index_buffer :: proc(render_pass: Render_Pass, #by_ptr binding: Buffer_Binding, index_element_size: Index_Size) {
	when METAL do mtl_bind_index_buffer(render_pass, binding, index_element_size)
	else when WEBGPU do wgpu_bind_index_buffer(render_pass, binding, index_element_size)
	else do vk_bind_index_buffer(render_pass, binding, index_element_size)
}

bind_vertex_buffers :: proc(render_pass: Render_Pass, first_slot: u32, bindings: [^]Buffer_Binding, num_bindings: u32) {
	when METAL do mtl_bind_vertex_buffers(render_pass, first_slot, bindings, num_bindings)
	else when WEBGPU do wgpu_bind_vertex_buffers(render_pass, first_slot, bindings, num_bindings)
	else do vk_bind_vertex_buffers(render_pass, first_slot, bindings, num_bindings)
}

bind_vertex_storage_buffers :: proc(render_pass: Render_Pass, first_slot: u32, storage_buffers: [^]Buffer, num_bindings: u32) {
	when METAL do mtl_bind_vertex_storage_buffers(render_pass, first_slot, storage_buffers, num_bindings)
	else when WEBGPU do wgpu_bind_vertex_storage_buffers(render_pass, first_slot, storage_buffers, num_bindings)
	else do vk_bind_vertex_storage_buffers(render_pass, first_slot, storage_buffers, num_bindings)
}

// Read-only storage buffers for the fragment stage, in the order the shader declares them.
bind_fragment_storage_buffers :: proc(render_pass: Render_Pass, first_slot: u32, storage_buffers: [^]Buffer, num_bindings: u32) {
	when METAL do mtl_bind_fragment_storage_buffers(render_pass, first_slot, storage_buffers, num_bindings)
	else when WEBGPU do wgpu_bind_fragment_storage_buffers(render_pass, first_slot, storage_buffers, num_bindings)
	else do vk_bind_fragment_storage_buffers(render_pass, first_slot, storage_buffers, num_bindings)
}

// Whether the recording holds anything for the GPU to run (a pass, a build, a mipmap
// chain, a copy staged and not yet recorded) or a swapchain image to present. One that
// holds none of these is as well cancelled as submitted: a submit of nothing still wakes
// the GPU and its driver. A staged copy counts: a cancel drops it, and a frame that drew
// nothing but uploaded (a simplified copy built while the app rested) lost those bytes,
// leaving the buffer's old ones where the draws then read. A timestamp alone is not work:
// a query never written reads as unavailable and is left out.
@(require_results)
command_buffer_recorded :: proc(command_buffer: Cmd) -> bool {
	if staging_pending(command_buffer) do return true
	when METAL do return mtl_command_buffer_recorded(command_buffer)
	else when WEBGPU do return wgpu_command_buffer_recorded(command_buffer)
	else do return vk_command_buffer_recorded(command_buffer)
}

@(require_results)
cancel_command_buffer :: proc(command_buffer: Cmd) -> bool {
	count_finish(command_buffer)
	staging_done(command_buffer, {}, false)
	when METAL do return mtl_cancel_command_buffer(command_buffer)
	else when WEBGPU do return wgpu_cancel_command_buffer(command_buffer)
	else do return vk_cancel_command_buffer(command_buffer)
}

@(require_results)
claim_window :: proc(window: ^sdl.Window) -> bool {
	when METAL do return mtl_claim_window(window)
	else when WEBGPU do return wgpu_claim_window(window)
	else do return vk_claim_window(window)
}

copy_buffer_to_buffer :: proc(copy_pass: Copy_Pass, #by_ptr source: Buffer_Location,         #by_ptr destination: Buffer_Location, size: u32, cycle: bool) {
	when METAL do mtl_copy_buffer_to_buffer(copy_pass, source, destination, size, cycle)
	else when WEBGPU do wgpu_copy_buffer_to_buffer(copy_pass, source, destination, size, cycle)
	else do vk_copy_buffer_to_buffer(copy_pass, source, destination, size, cycle)
}

copy_texture_to_texture :: proc(copy_pass: Copy_Pass, #by_ptr source: Texture_Location,        #by_ptr destination: Texture_Location, w, h, d: u32, cycle: bool) {
	transient_check_use(source.texture, "copied from")
	transient_check_use(destination.texture, "copied to")
	when METAL do mtl_copy_texture_to_texture(copy_pass, source, destination, w, h, d, cycle)
	else when WEBGPU do wgpu_copy_texture_to_texture(copy_pass, source, destination, w, h, d, cycle)
	else do vk_copy_texture_to_texture(copy_pass, source, destination, w, h, d, cycle)
}

// `accel_input` for a buffer an acceleration structure is built from (build_blas),
// which only the own Vulkan backend with ray queries marks; elsewhere it changes nothing.
@(require_results)
create_buffer :: proc(#by_ptr createinfo: Buffer_Desc, accel_input := false) -> Buffer {
	when METAL do return Buffer(pool_add(&pools.buffers, mtl_create_buffer(createinfo)))
	else when WEBGPU do return Buffer(pool_add(&pools.buffers, wgpu_create_buffer(createinfo)))
	else do return Buffer(pool_add(&pools.buffers, vk_create_buffer(createinfo, accel_input)))
}

@(require_results)
create_compute_pipeline :: proc(#by_ptr createinfo: Compute_Pipeline_Desc) -> Compute_Pipeline {
	when METAL do return Compute_Pipeline(pool_add(&pools.compute_pipelines, mtl_create_compute_pipeline(createinfo)))
	else when WEBGPU do return Compute_Pipeline(pool_add(&pools.compute_pipelines, wgpu_create_compute_pipeline(createinfo)))
	else do return Compute_Pipeline(pool_add(&pools.compute_pipelines, vk_create_compute_pipeline(createinfo)))
}

// A compute pipeline that also reads an array of up to `capacity` sampled textures, indexed
// per thread (set 3, binding 0 in SPIR-V): the own Vulkan backend with descriptor indexing
// only, up to Gpu_Caps.texture_arrays; nil with SDL's error set elsewhere, and the caller
// keeps a kernel with named samplers.
@(require_results)
create_compute_pipeline_array :: proc(#by_ptr createinfo: Compute_Pipeline_Desc, capacity: u32) -> Compute_Pipeline {
	when METAL {
		fail(.Unsupported, "texture arrays need the own Vulkan backend")
		return 0
	} else when WEBGPU {
		fail(.Unsupported, "texture arrays need the own Vulkan backend")
		return 0
	} else {
		return Compute_Pipeline(pool_add(&pools.compute_pipelines, vk_create_compute_pipeline_array(createinfo, capacity)))
	}
}

// How many textures one array binding may hold; 0 where create_compute_pipeline_array
// makes nothing.
@(require_results)
texture_arrays_offered :: proc() -> u32 {
	when METAL do return 0
	else when WEBGPU do return 0
	else do return vk_state.texture_arrays
}

// How many storage buffers one compute kernel may bind: the device's own limit under
// Vulkan (the spec asks only 4), Metal's 31 buffer slots, WebGPU's default 8.
@(require_results)
storage_buffers_per_stage :: proc() -> u32 {
	when METAL do return 31
	else when WEBGPU do return 8
	else do return vk_state.properties.limits.maxPerStageDescriptorStorageBuffers
}

// The memory the GPU's buffers can use, in bytes, and whether it is the system's own
// memory (a unified-memory GPU: Apple's, Android's, an integrated one), where it is shared
// with everything the CPU holds: Metal's recommended working set; under Vulkan the largest
// device-local heap; 0 under WebGPU, which does not say.
@(require_results)
memory_budget :: proc() -> (bytes: u64, unified: bool) {
	when METAL do return mtl_memory_budget()
	else when WEBGPU do return 0, false
	else {
		for i in 0 ..< vk_state.memory.memoryHeapCount {
			h := vk_state.memory.memoryHeaps[i]
			if .DEVICE_LOCAL in h.flags do bytes = max(bytes, u64(h.size))
		}
		type := vk_state.properties.deviceType
		return bytes, type == .INTEGRATED_GPU || type == .CPU
	}
}

// The most threads one compute workgroup may run (Vulkan's maxComputeWorkGroupInvocations,
// and its first dimension's size): Metal's pipelines say for themselves when they are
// made (mtl_compute_pipeline_make refuses one that cannot), and WebGPU's default is 256.
@(require_results)
compute_group_threads :: proc() -> u32 {
	when METAL do return 1024
	else when WEBGPU do return 256
	else do return min(vk_state.properties.limits.maxComputeWorkGroupInvocations, vk_state.properties.limits.maxComputeWorkGroupSize[0])
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
	transform: matrix[4, 4]f32,
	custom:    u32,
}

// Fragment shaders read where the pixel lies between the triangle's corners
// (Gpu_Caps.barycentric): VK_KHR_fragment_shader_barycentric under the own Vulkan backend,
// supportsShaderBarycentricCoordinates under the own Metal one.
@(require_results)
barycentric_offered :: proc() -> bool {
	when METAL do return mtl_barycentric_offered()
	else when WEBGPU do return wgpu_barycentric_offered()
	else when WEBGPU do return false
	else do return vk_state.barycentric
}

@(require_results)
ray_query_offered :: proc() -> bool {
	when METAL do return mtl_ray_query_offered()
	else when WEBGPU do return wgpu_ray_query_offered()
	else when WEBGPU do return false
	else do return vk_state.ray_query
}

// Records a bottom-level build over `positions` (3 floats a vertex, `vertex_count` of them)
// and `indices` (u32), both made with accel_input, outside any pass. With `update` and the
// same geometries it refits that structure in place and returns it; otherwise it returns a
// new one, and the caller releases `update`. Nil where nothing is offered or the build
// cannot be made.
@(require_results)
build_blas :: proc(command_buffer: Cmd, positions, indices: Buffer, vertex_count: u32, geometries: []Blas_Geometry, update: ^Gpu_Accel = nil) -> ^Gpu_Accel {
	staging_flush(command_buffer)
	when METAL {
		if mtl_ray_query_offered() do return mtl_build_blas(command_buffer, positions, indices, vertex_count, geometries, update)
		return nil
	} else when WEBGPU {
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
build_tlas :: proc(command_buffer: Cmd, instances: []Tlas_Instance, update: ^Gpu_Accel = nil) -> ^Gpu_Accel {
	staging_flush(command_buffer)
	when METAL {
		if mtl_ray_query_offered() do return mtl_build_tlas(command_buffer, instances, update)
		return nil
	} else when WEBGPU {
		return nil
	} else {
		if vk_state.ray_query do return vk_build_tlas(command_buffer, instances, update)
		return nil
	}
}

// A compute pipeline that traces against the top level at set 3, binding 0 in SPIR-V, and
// also reads an array of up to `capacity` sampled textures at binding 1 (none for 0); nil
// with SDL's error set where ray queries are not offered. Under Metal the kernel's slot
// table must name its structure, and texture arrays are not offered.
@(require_results)
create_compute_pipeline_traced :: proc(#by_ptr createinfo: Compute_Pipeline_Desc, capacity: u32 = 0) -> Compute_Pipeline {
	when METAL {
		if mtl_ray_query_offered() && capacity == 0 do return Compute_Pipeline(pool_add(&pools.compute_pipelines, mtl_create_compute_pipeline_traced(createinfo)))
		fail(.Unsupported, "ray queries need the own Vulkan or Metal backend on a GPU that offers them")
		return 0
	} else when WEBGPU {
		fail(.Unsupported, "WebGPU has no ray queries")
		return 0
	} else {
		return Compute_Pipeline(pool_add(&pools.compute_pipelines, vk_create_compute_pipeline_traced(createinfo, capacity)))
	}
}

// The top level a create_compute_pipeline_traced kernel traces against at its next
// dispatch in this pass.
bind_compute_accel :: proc(compute_pass: Compute_Pass, accel: ^Gpu_Accel) {
	when METAL do mtl_bind_compute_accel(compute_pass, accel)
	else when WEBGPU do return
	else do vk_bind_compute_accel(compute_pass, accel)
}

// Frees a structure once no submitted command buffer and no top level uses it.
release_accel :: proc(accel: ^Gpu_Accel) {
	when METAL do mtl_release_accel(accel)
	else when WEBGPU do return
	else do if accel != nil do vk_release_accel(accel)
}

// Lets go of the build scratch memory beyond what refits need, once a still view's builds
// are recorded; it goes when they have run. Metal gives each build scratch of its own,
// freed with its command buffer, so there is nothing to trim there.
accel_trim :: proc() {
	when VULKAN {
		if vk_state.ray_query do vk_accel_trim()
	}
}

// Where a buffer made with accel_input lies in the GPU's memory, for a ray query kernel
// that reads it through that address; `command_buffer` keeps it alive until it has run.
// 0 where ray queries are not offered.
@(require_results)
buffer_address :: proc(command_buffer: Cmd, buffer: Buffer) -> u64 {
	when METAL {
		if mtl_ray_query_offered() do return mtl_buffer_address(command_buffer, buffer)
		return 0
	} else when WEBGPU {
		return 0
	} else {
		if vk_state.ray_query do return vk_buffer_address(command_buffer, buffer)
		return 0
	}
}

// The GPU memory a structure holds, for budgets and the exit stats.
@(require_results)
accel_bytes :: proc(accel: ^Gpu_Accel) -> u64 {
	when METAL {
		if accel != nil do return mtl_accel_bytes(accel)
		return 0
	} else when WEBGPU {
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
create_compute_pipeline_exact :: proc(#by_ptr createinfo: Compute_Pipeline_Desc) -> Compute_Pipeline {
	when METAL do return Compute_Pipeline(pool_add(&pools.compute_pipelines, mtl_create_compute_pipeline_exact(createinfo)))
	else when WEBGPU do return Compute_Pipeline(pool_add(&pools.compute_pipelines, wgpu_create_compute_pipeline_exact(createinfo)))
	else do return Compute_Pipeline(pool_add(&pools.compute_pipelines, vk_create_compute_pipeline(createinfo)))
}

@(require_results)
create_graphics_pipeline :: proc(#by_ptr createinfo: Graphics_Pipeline_Desc) -> Graphics_Pipeline {
	when METAL do return Graphics_Pipeline(pool_add(&pools.graphics_pipelines, mtl_create_graphics_pipeline(createinfo)))
	else when WEBGPU do return Graphics_Pipeline(pool_add(&pools.graphics_pipelines, wgpu_create_graphics_pipeline(createinfo)))
	else do return Graphics_Pipeline(pool_add(&pools.graphics_pipelines, vk_create_graphics_pipeline(createinfo)))
}

@(require_results)
create_sampler :: proc(#by_ptr createinfo: Sampler_Desc) -> Sampler {
	when METAL do return Sampler(pool_add(&pools.samplers, mtl_create_sampler(createinfo)))
	else when WEBGPU do return Sampler(pool_add(&pools.samplers, wgpu_create_sampler(createinfo)))
	else do return Sampler(pool_add(&pools.samplers, vk_create_sampler(createinfo)))
}

@(require_results)
create_shader :: proc(#by_ptr createinfo: Shader_Desc) -> Shader {
	when METAL do return Shader(pool_add(&pools.shaders, mtl_create_shader(createinfo)))
	else when WEBGPU do return Shader(pool_add(&pools.shaders, wgpu_create_shader(createinfo)))
	else do return Shader(pool_add(&pools.shaders, vk_create_shader(createinfo)))
}

@(require_results)
create_texture :: proc(#by_ptr createinfo: Texture_Desc) -> Texture {
	when METAL do return Texture(pool_add(&pools.textures, mtl_create_texture(createinfo)))
	else when WEBGPU do return Texture(pool_add(&pools.textures, wgpu_create_texture(createinfo)))
	else do return Texture(pool_add(&pools.textures, vk_create_texture(createinfo)))
}

// A render target whose contents live only inside the pass that clears it (transient.odin):
// usage COLOR_TARGET or DEPTH_STENCIL_TARGET alone, never loaded, stored, sampled or copied.
// Memoryless on the own Metal backend, lazily allocated where the own Vulkan backend's
// device offers it (tile GPUs), a plain target otherwise.
@(require_results)
create_texture_transient :: proc(#by_ptr createinfo: Texture_Desc) -> (texture: Texture) {
	assert(createinfo.usage <= {.Color_Target, .Depth_Target}, "a transient texture is a render target only")
	make_it :: proc(#by_ptr createinfo: Texture_Desc) -> Texture {
		when METAL do return Texture(pool_add(&pools.textures, mtl_create_texture_transient(createinfo)))
		else when WEBGPU do return Texture(pool_add(&pools.textures, wgpu_create_texture_transient(createinfo)))
		else do return Texture(pool_add(&pools.textures, vk_create_texture_transient(createinfo)))
	}
	texture = make_it(createinfo)
	transient_note(texture)
	return
}

// Whether transient textures save memory: a lazily allocated memory type under the own
// Vulkan backend, any Apple GPU under the own Metal one.
@(require_results)
transient_targets_offered :: proc() -> bool {
	when METAL do return true
	else when WEBGPU do return false
	else do return vk_state.lazy_memory
}

@(require_results)
// Transfer buffers are staging's own (staging.odin): render moves bytes through
// upload, stage_buffer and readbacks, so these are private to the package.
@(private)
create_transfer_buffer :: proc(#by_ptr createinfo: Transfer_Buffer_Desc) -> Transfer_Buffer {
	when METAL do return Transfer_Buffer(pool_add(&pools.transfer_buffers, mtl_create_transfer_buffer(createinfo)))
	else when WEBGPU do return Transfer_Buffer(pool_add(&pools.transfer_buffers, wgpu_create_transfer_buffer(createinfo)))
	else do return Transfer_Buffer(pool_add(&pools.transfer_buffers, vk_create_transfer_buffer(createinfo)))
}

destroy_device :: proc() {
	staging_reset()
	when METAL do mtl_destroy_device()
	else when WEBGPU do wgpu_destroy_device()
	else do vk_destroy_device()
	pools_reset()
}

dispatch_compute :: proc(compute_pass: Compute_Pass, groupcount_x, groupcount_y, groupcount_z: u32) {
	when METAL do mtl_dispatch_compute(compute_pass, groupcount_x, groupcount_y, groupcount_z)
	else when WEBGPU do wgpu_dispatch_compute(compute_pass, groupcount_x, groupcount_y, groupcount_z)
	else do vk_dispatch_compute(compute_pass, groupcount_x, groupcount_y, groupcount_z)
}

@(private)
download_from_buffer :: proc(copy_pass: Copy_Pass, #by_ptr source: Buffer_Region,           #by_ptr destination: Transfer_Buffer_Location) {
	when METAL do mtl_download_from_buffer(copy_pass, source, destination)
	else when WEBGPU do wgpu_download_from_buffer(copy_pass, source, destination)
	else do vk_download_from_buffer(copy_pass, source, destination)
}

@(private)
download_from_texture :: proc(copy_pass: Copy_Pass, #by_ptr source: Texture_Region,          #by_ptr destination: Texture_Transfer_Info) {
	transient_check_use(source.texture, "downloaded")
	when METAL do mtl_download_from_texture(copy_pass, source, destination)
	else when WEBGPU do wgpu_download_from_texture(copy_pass, source, destination)
	else do vk_download_from_texture(copy_pass, source, destination)
}

draw_indexed_primitives :: proc(render_pass: Render_Pass, num_indices: u32,  num_instances: u32, first_index:  u32, vertex_offset: i32, first_instance: u32) {
	when METAL do mtl_draw_indexed_primitives(render_pass, num_indices, num_instances, first_index, vertex_offset, first_instance)
	else when WEBGPU do wgpu_draw_indexed_primitives(render_pass, num_indices, num_instances, first_index, vertex_offset, first_instance)
	else do vk_draw_indexed_primitives(render_pass, num_indices, num_instances, first_index, vertex_offset, first_instance)
}

draw_indexed_primitives_indirect :: proc(render_pass: Render_Pass, buffer: Buffer, offset: u32, draw_count: u32) {
	when METAL do mtl_draw_indexed_primitives_indirect(render_pass, buffer, offset, draw_count)
	else when WEBGPU do wgpu_draw_indexed_primitives_indirect(render_pass, buffer, offset, draw_count)
	else do vk_draw_indexed_primitives_indirect(render_pass, buffer, offset, draw_count)
}

// Non-indexed indirect draws, `stride` bytes apart. With the stride of an indexed command
// (size_of(Indexed_Indirect_Draw)), the indexed commands a mesh's culling wrote
// draw as non-indexed ones over the same index positions, for shaders that read the index
// buffer themselves (the detail skin's, which take a triangle's number from its vertex's).
draw_primitives_indirect :: proc(render_pass: Render_Pass, buffer: Buffer, offset, draw_count, stride: u32) {
	when METAL do mtl_draw_primitives_indirect(render_pass, buffer, offset, draw_count, stride)
	else when WEBGPU do wgpu_draw_primitives_indirect(render_pass, buffer, offset, draw_count, stride)
	else do vk_draw_primitives_indirect(render_pass, buffer, offset, draw_count, stride)
}

// draw_primitives_indirect with its count written by a kernel. Only where
// cull_offered.
draw_primitives_indirect_count :: proc(render_pass: Render_Pass, buffer: Buffer, offset: u32, count_buffer: Buffer, count_offset, max_draws, stride: u32) {
	when VULKAN {
		vk_draw_primitives_indirect_count(render_pass, buffer, offset, count_buffer, count_offset, max_draws, stride)
	}
}

// An indirect draw whose count a kernel wrote: up to `max_draws` commands from `offset`,
// as many as the u32 at `count_offset` of `count_buffer` says. Only where
// cull_offered.
draw_indexed_primitives_indirect_count :: proc(render_pass: Render_Pass, buffer: Buffer, offset: u32, count_buffer: Buffer, count_offset: u32, max_draws: u32) {
	when VULKAN {
		vk_draw_indexed_primitives_indirect_count(render_pass, buffer, offset, count_buffer, count_offset, max_draws)
	}
}

// Whether objects' chunks can be culled on the GPU (gpu_cull.odin): the own Vulkan backend
// with indirect draws that take many commands and read their count from a buffer, so the
// culled-away chunks cost the GPU nothing.
@(require_results)
cull_offered :: proc() -> bool {
	when METAL do return false
	else when WEBGPU do return false
	else do return vk_state.multi_draw && vk_state.indirect_count
}

// Whether GPU culling, where offered, starts on. Not on a tile GPU (one with lazily
// allocated memory: the tablets' and phones'), whose command processor may read every
// command up to the most a draw may take: there it is offered off, for a tablet's
// numbers to say whether it pays (Stats > Drawing, --gpu-cull).
@(require_results)
cull_by_default :: proc() -> bool {
	when METAL do return false
	else when WEBGPU do return false
	else do return !vk_state.lazy_memory
}

draw_primitives :: proc(render_pass: Render_Pass, num_vertices: u32, num_instances: u32, first_vertex: u32, first_instance: u32) {
	when METAL do mtl_draw_primitives(render_pass, num_vertices, num_instances, first_vertex, first_instance)
	else when WEBGPU do wgpu_draw_primitives(render_pass, num_vertices, num_instances, first_vertex, first_instance)
	else do vk_draw_primitives(render_pass, num_vertices, num_instances, first_vertex, first_instance)
}

end_compute_pass :: proc(compute_pass: Compute_Pass) {
	when METAL do mtl_end_compute_pass(compute_pass)
	else when WEBGPU do wgpu_end_compute_pass(compute_pass)
	else do vk_end_compute_pass(compute_pass)
}

end_copy_pass :: proc(copy_pass: Copy_Pass) {
	when METAL do mtl_end_copy_pass(copy_pass)
	else when WEBGPU do wgpu_end_copy_pass(copy_pass)
	else do vk_end_copy_pass(copy_pass)
}

end_render_pass :: proc(render_pass: Render_Pass) {
	when METAL do mtl_end_render_pass(render_pass)
	else when WEBGPU do wgpu_end_render_pass(render_pass)
	else do vk_end_render_pass(render_pass)
}

@(require_results)
texture_supports_format :: proc(format: Format, type: Texture_Type, usage: Texture_Usages) -> bool {
	when METAL do return mtl_texture_supports_format(format, type, usage)
	else when WEBGPU do return wgpu_texture_supports_format(format, type, usage)
	else do return vk_texture_supports_format(format, type, usage)
}

@(require_results)
texture_supports_sample_count :: proc(format: Format, sample_count: Sample_Count) -> bool {
	when METAL do return mtl_texture_supports_sample_count(format, sample_count)
	else when WEBGPU do return wgpu_texture_supports_sample_count(format, sample_count)
	else do return vk_texture_supports_sample_count(format, sample_count)
}

generate_mipmaps_for_texture :: proc(command_buffer: Cmd, texture: Texture) {
	staging_flush(command_buffer)
	transient_check_use(texture, "mipmapped")
	when METAL do mtl_generate_mipmaps_for_texture(command_buffer, texture)
	else when WEBGPU do wgpu_generate_mipmaps_for_texture(command_buffer, texture)
	else do vk_generate_mipmaps_for_texture(command_buffer, texture)
}

@(require_results)
get_swapchain_texture_format :: proc(window: ^sdl.Window) -> Format {
	when METAL do return mtl_get_swapchain_texture_format(window)
	else when WEBGPU do return wgpu_get_swapchain_texture_format(window)
	else do return vk_get_swapchain_texture_format(window)
}

@(require_results)
@(private)
map_transfer_buffer :: proc(transfer_buffer: Transfer_Buffer, cycle: bool) -> rawptr {
	when METAL do return mtl_map_transfer_buffer(transfer_buffer, cycle)
	else when WEBGPU do return wgpu_map_transfer_buffer(transfer_buffer, cycle)
	else do return vk_map_transfer_buffer(transfer_buffer, cycle)
}

push_compute_uniform_data :: proc(command_buffer: Cmd, slot_index: u32, data: rawptr, length: u32) {
	when METAL do mtl_push_compute_uniform_data(command_buffer, slot_index, data, length)
	else when WEBGPU do wgpu_push_compute_uniform_data(command_buffer, slot_index, data, length)
	else do vk_push_compute_uniform_data(command_buffer, slot_index, data, length)
}

push_fragment_uniform_data :: proc(command_buffer: Cmd, slot_index: u32, data: rawptr, length: u32) {
	when METAL do mtl_push_fragment_uniform_data(command_buffer, slot_index, data, length)
	else when WEBGPU do wgpu_push_fragment_uniform_data(command_buffer, slot_index, data, length)
	else do vk_push_fragment_uniform_data(command_buffer, slot_index, data, length)
}

push_vertex_uniform_data :: proc(command_buffer: Cmd, slot_index: u32, data: rawptr, length: u32) {
	when METAL do mtl_push_vertex_uniform_data(command_buffer, slot_index, data, length)
	else when WEBGPU do wgpu_push_vertex_uniform_data(command_buffer, slot_index, data, length)
	else do vk_push_vertex_uniform_data(command_buffer, slot_index, data, length)
}

// Whether the GPU has run every submission of the ticket's queue up to it.
@(require_results)
done :: proc(ticket: Ticket) -> bool {
	if ticket.value == 0 do return true
	when METAL do return mtl_ticket_done(ticket)
	else when WEBGPU do return wgpu_ticket_done(ticket)
	else do return vk_ticket_done(ticket)
}

// Releasing is safe at any time, with frames or compute still in flight, or in the middle
// of a recording that used the object: the handle stops resolving at once, and each
// backend frees the object only when no command buffer recorded or in flight still uses
// it (Vulkan and Metal count each backing's uses, Metal's command buffers retain what they
// encode, and WebGPU destroys after the work submitted before it). So nothing waits for
// the GPU before freeing.
release_buffer :: proc(buffer: Buffer) {
	when METAL do mtl_release_buffer(pool_remove(&pools.buffers, u32(buffer)))
	else when WEBGPU do wgpu_release_buffer(pool_remove(&pools.buffers, u32(buffer)))
	else do vk_release_buffer(pool_remove(&pools.buffers, u32(buffer)))
}

release_compute_pipeline :: proc(compute_pipeline: Compute_Pipeline) {
	when METAL do mtl_release_compute_pipeline(pool_remove(&pools.compute_pipelines, u32(compute_pipeline)))
	else when WEBGPU do wgpu_release_compute_pipeline(pool_remove(&pools.compute_pipelines, u32(compute_pipeline)))
	else do vk_release_compute_pipeline(pool_remove(&pools.compute_pipelines, u32(compute_pipeline)))
}

release_graphics_pipeline :: proc(graphics_pipeline: Graphics_Pipeline) {
	when METAL do mtl_release_graphics_pipeline(pool_remove(&pools.graphics_pipelines, u32(graphics_pipeline)))
	else when WEBGPU do wgpu_release_graphics_pipeline(pool_remove(&pools.graphics_pipelines, u32(graphics_pipeline)))
	else do vk_release_graphics_pipeline(pool_remove(&pools.graphics_pipelines, u32(graphics_pipeline)))
}

release_sampler :: proc(sampler: Sampler) {
	when METAL do mtl_release_sampler(pool_remove(&pools.samplers, u32(sampler)))
	else when WEBGPU do wgpu_release_sampler(pool_remove(&pools.samplers, u32(sampler)))
	else do vk_release_sampler(pool_remove(&pools.samplers, u32(sampler)))
}

release_shader :: proc(shader: Shader) {
	when METAL do mtl_release_shader(pool_remove(&pools.shaders, u32(shader)))
	else when WEBGPU do wgpu_release_shader(pool_remove(&pools.shaders, u32(shader)))
	else do vk_release_shader(pool_remove(&pools.shaders, u32(shader)))
}

release_texture :: proc(texture: Texture) {
	transient_forget(texture)
	when METAL do mtl_release_texture(pool_remove(&pools.textures, u32(texture)))
	else when WEBGPU do wgpu_release_texture(pool_remove(&pools.textures, u32(texture)))
	else do vk_release_texture(pool_remove(&pools.textures, u32(texture)))
}

@(private)
release_transfer_buffer :: proc(transfer_buffer: Transfer_Buffer) {
	when METAL do mtl_release_transfer_buffer(pool_remove(&pools.transfer_buffers, u32(transfer_buffer)))
	else when WEBGPU do wgpu_release_transfer_buffer(pool_remove(&pools.transfer_buffers, u32(transfer_buffer)))
	else do vk_release_transfer_buffer(pool_remove(&pools.transfer_buffers, u32(transfer_buffer)))
}

release_window :: proc(window: ^sdl.Window) {
	when METAL do mtl_release_window(window)
	else when WEBGPU do wgpu_release_window(window)
	else do vk_release_window(window)
}

set_scissor :: proc(render_pass: Render_Pass, #by_ptr scissor: Rect) {
	when METAL do mtl_set_scissor(render_pass, scissor)
	else when WEBGPU do wgpu_set_scissor(render_pass, scissor)
	else do vk_set_scissor(render_pass, scissor)
}

push_debug_group :: proc(command_buffer: Cmd, name: cstring) {
	when METAL do mtl_push_debug_group(command_buffer, name)
	else when WEBGPU do wgpu_push_debug_group(command_buffer, name)
	else do vk_push_debug_group(command_buffer, name)
}

pop_debug_group :: proc(command_buffer: Cmd) {
	when METAL do mtl_pop_debug_group(command_buffer)
	else when WEBGPU do wgpu_pop_debug_group(command_buffer)
	else do vk_pop_debug_group(command_buffer)
}

set_buffer_name :: proc(buffer: Buffer, text: cstring) {
	when METAL do mtl_set_buffer_name(buffer, text)
	else when WEBGPU do wgpu_set_buffer_name(buffer, text)
	else do vk_set_buffer_name(buffer, text)
}

set_texture_name :: proc(texture: Texture, text: cstring) {
	when METAL do mtl_set_texture_name(texture, text)
	else when WEBGPU do wgpu_set_texture_name(texture, text)
	else do vk_set_texture_name(texture, text)
}

@(require_results)
set_allowed_frames_in_flight :: proc(allowed_frames_in_flight: u32) -> bool {
	when METAL do return mtl_set_allowed_frames_in_flight(allowed_frames_in_flight)
	else when WEBGPU do return wgpu_set_allowed_frames_in_flight(allowed_frames_in_flight)
	else do return vk_set_allowed_frames_in_flight(allowed_frames_in_flight)
}

// When a frame reached the screen, as far as each backend can tell (Gpu_Caps.present_timing).
@(require_results)
present_timing :: proc() -> Present_Timing {
	when METAL do return .Presented_Handler
	else when WEBGPU do return .None
	else do return vk_state.present_timing
}

present_input :: proc(window: ^sdl.Window, input_ns: u64) {
	when METAL do mtl_present_input(window, input_ns)
	else when WEBGPU do wgpu_present_input(window, input_ns)
	else do vk_present_input(window, input_ns)
}

@(require_results)
present_times :: proc(window: ^sdl.Window, out: []Present_Time) -> int {
	when METAL do return mtl_present_times(window, out)
	else when WEBGPU do return wgpu_present_times(window, out)
	else do return vk_present_times(window, out)
}

// Frames presented that never reached the screen, since the device was made; `known` false
// where the backend cannot tell (only the own Metal backend's presented handlers can).
@(require_results)
frames_dropped :: proc() -> (dropped: u64, known: bool) {
	when METAL do return mtl_frames_dropped(), true
	else do return 0, false
}

// Display-link pacing, which only the own Metal backend has (mtl_link.odin).
@(require_results)
display_link_offered :: proc() -> bool {
	return METAL
}

set_display_link :: proc(on: bool) {
	when METAL do mtl_state.link_wanted = on
}

@(require_results)
display_link_frames :: proc() -> u64 {
	when METAL do return mtl_link_frames()
	else do return 0
}

// Whether create_buffer_mapped makes buffers: the own Vulkan backend with a shared
// memory type (vk_pick_shared_type), the own Metal backend on unified memory.
@(require_results)
shared_buffers_offered :: proc() -> bool {
	when METAL do return mtl_shared_buffers_offered()
	else when WEBGPU do return wgpu_shared_buffers_offered()
	else do return vk_state.shared_buffers
}

// A device buffer whose `info.size` bytes the CPU writes through `mapped` before anything
// uses it, then ends with buffer_filled; nil, nil where the backend cannot, and the
// caller uploads into a plain buffer instead.
@(require_results)
create_buffer_mapped :: proc(#by_ptr info: Buffer_Desc, accel_input := false) -> (buffer: Buffer, mapped: rawptr) {
	object: rawptr
	when METAL do object, mapped = mtl_create_buffer_mapped(info)
	else when WEBGPU do object, mapped = wgpu_create_buffer_mapped(info)
	else do object, mapped = vk_create_buffer_mapped(info, accel_input)
	return Buffer(pool_add(&pools.buffers, object)), mapped
}

// Ends the fill of a create_buffer_mapped buffer; the mapped pointer is invalid after.
buffer_filled :: proc(buffer: Buffer) {
	when VULKAN {
		vk_buffer_filled(buffer)
	}
}

// GPU timestamps, the own Vulkan backend's only: Apple GPUs sample counters only where a
// pass begins or ends, so the own Metal backend would time passes, not the debug groups
// these timestamps bracket.
@(require_results)
timestamps_offered :: proc() -> bool {
	when METAL do return false
	else when WEBGPU do return false
	else do return vk_state.timing.slots[0].pool != 0
}

write_timestamp :: proc(command_buffer: Cmd, tag: u8) {
	when VULKAN {
		vk_write_timestamp((^Vk_Cmd)(command_buffer), tag)
	}
}

@(require_results)
timestamps_frame :: proc(out: []Gpu_Timestamp) -> int {
	when METAL || WEBGPU do return 0
	else do return vk_timestamps_frame(out)
}

// Pre-rotation: Apple's compositor turns Metal's images at no cost, so only the own Vulkan
// backend's are turned.
@(require_results)
swapchain_turns :: proc(window: ^sdl.Window) -> int {
	when METAL || WEBGPU do return 0
	else do return vk_swapchain_turns(window)
}

@(require_results)
set_swapchain_parameters :: proc(window: ^sdl.Window, swapchain_composition: Swapchain_Composition, present_mode: Present_Mode) -> bool {
	when METAL do return mtl_set_swapchain_parameters(window, swapchain_composition, present_mode)
	else when WEBGPU do return wgpu_set_swapchain_parameters(window, swapchain_composition, present_mode)
	else do return vk_set_swapchain_parameters(window, swapchain_composition, present_mode)
}

// Sends the recording to its queue and hands back its ticket; false (with last_error)
// where the device refused it.
@(require_results)
submit :: proc(command_buffer: Cmd) -> (ticket: Ticket, ok: bool) {
	count_finish(command_buffer)
	staging_flush(command_buffer)
	when METAL do ticket, ok = mtl_submit_command_buffer(command_buffer)
	else when WEBGPU do ticket, ok = wgpu_submit_command_buffer(command_buffer)
	else do ticket, ok = vk_submit_command_buffer(command_buffer)
	staging_done(command_buffer, ticket, ok)
	return
}

@(private)
unmap_transfer_buffer :: proc(transfer_buffer: Transfer_Buffer) {
	when METAL do mtl_unmap_transfer_buffer(transfer_buffer)
	else when WEBGPU do wgpu_unmap_transfer_buffer(transfer_buffer)
	else do vk_unmap_transfer_buffer(transfer_buffer)
}

@(private)
upload_to_buffer :: proc(copy_pass: Copy_Pass, #by_ptr source: Transfer_Buffer_Location, #by_ptr destination: Buffer_Region, cycle: bool) {
	when METAL do mtl_upload_to_buffer(copy_pass, source, destination, cycle)
	else when WEBGPU do wgpu_upload_to_buffer(copy_pass, source, destination, cycle)
	else do vk_upload_to_buffer(copy_pass, source, destination, cycle)
}

@(private)
upload_to_texture :: proc(copy_pass: Copy_Pass, #by_ptr source: Texture_Transfer_Info,    #by_ptr destination: Texture_Region, cycle: bool) {
	transient_check_use(destination.texture, "uploaded to")
	when METAL do mtl_upload_to_texture(copy_pass, source, destination, cycle)
	else when WEBGPU do wgpu_upload_to_texture(copy_pass, source, destination, cycle)
	else do vk_upload_to_texture(copy_pass, source, destination, cycle)
}

@(require_results)
wait_and_acquire_swapchain_texture :: proc(command_buffer: Cmd, window: ^sdl.Window, swapchain_texture: ^Texture, swapchain_texture_width, swapchain_texture_height: ^u32) -> bool {
	start := time.tick_now()
	defer count_pause(command_buffer, time.tick_since(start))
	when METAL do return mtl_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, true)
	else when WEBGPU do return wgpu_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, true)
	else do return vk_acquire_swapchain(command_buffer, window, swapchain_texture, swapchain_texture_width, swapchain_texture_height, true)
}

// Waits until every ticket is done. Under WebGPU a page cannot block, and this answers
// true at once (wgpu_wait): a readback polls done there instead.
wait :: proc(tickets: ..Ticket) -> bool {
	pending := false
	for t in tickets do if !done(t) do pending = true
	if !pending do return true
	count_wait()
	when METAL do return mtl_wait(tickets)
	else when WEBGPU do return wgpu_wait(tickets)
	else do return vk_wait(tickets)
}

@(require_results)
wait_for_idle :: proc() -> bool {
	count_idle_wait()
	when METAL do return mtl_wait_for_idle()
	else when WEBGPU do return wgpu_wait_for_idle()
	else do return vk_wait_for_idle()
}

@(require_results)
window_supports_present_mode :: proc(window: ^sdl.Window, present_mode: Present_Mode) -> bool {
	when METAL do return mtl_window_supports_present_mode(window, present_mode)
	else when WEBGPU do return wgpu_window_supports_present_mode(window, present_mode)
	else do return vk_window_supports_present_mode(window, present_mode)
}

// Makes the device for the platform's backend, or false with backend_error saying
// why when it falls short of the app's needs. `anisotropy` says whether its samplers may
// filter anisotropically (Android's Vulkan is not asked to).
@(require_results)
create_device :: proc(debug: bool) -> (anisotropy: bool, ok: bool) {
	when METAL do return true, mtl_create_device(debug)
	else when WEBGPU do return true, wgpu_create_device(debug)
	else {
		ok = vk_create_device(debug, ODIN_PLATFORM_SUBTARGET != .Android)
		return vk_state.anisotropy, ok
	}
}

// A misuse render finds itself under --gpu-debug: on Vulkan it counts as a validation error,
// so the checks that fail on the layer's errors fail on it; elsewhere it is logged.
validation_error :: proc(format: string, args: ..any) {
	when VULKAN {
		vk_validation_error(format, ..args)
	} else {
		log.errorf(format, ..args)
	}
}

// Lets the Vulkan backend pre-rotate (on Android it does by default); set before the window
// is claimed. --no-pre-rotate turns it off to compare.
set_pre_rotate :: proc(on: bool) {
	when VULKAN do vk_pre_rotate = on
}
