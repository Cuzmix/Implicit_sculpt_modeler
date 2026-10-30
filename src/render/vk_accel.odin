package render

import "core:log"
import "core:slice"

import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// Acceleration structures for ray queries (native GPU plan 6.1,
// notes/native-gpu/ray-query-design.md): the driver's own trees over a mesh's triangles
// (bottom level) and over the scene's instances of them (top level), which kernels trace
// with RayQuery instead of walking our BVH. Builds are recorded on the graphics queue,
// outside passes, with a full barrier on each side, so whatever ran before has finished
// writing their inputs and whatever runs after sees the structure. Each structure counts
// the command buffers that use it, and a top level counts as a user of each bottom level
// it instances, so a release frees it only once nothing can still trace it.

Vk_Accel :: struct {
	handle:         vk.AccelerationStructureKHR,
	buffer:         ^Vk_Buffer, // the structure's storage; released with it
	address:        vk.DeviceAddress,
	top:            bool,
	bytes:          u64,
	// A bottom level's geometries and vertex count as built: a refit must keep both.
	geometries:     [dynamic]Blas_Geometry,
	vertex_count:   u32,
	build_scratch:  vk.DeviceSize,
	update_scratch: vk.DeviceSize,
	// A top level's bottom levels, each holding one reference from it.
	instances:      [dynamic]^Vk_Accel,
	refs:           i32,
	stamp:          u64,
	released:       bool,
}

// VkAccelerationStructureInstanceKHR as the GPU reads it. It is written as plain words
// because the binding types the flags byte as one enum value rather than a set of bits.
@(private = "file")
Vk_Instance :: struct {
	transform:    [3][4]f32, // the top three rows, row-major
	custom_mask:  u32,       // the custom index in the low 24 bits, the visibility mask in the top 8
	offset_flags: u32,       // the shader binding table offset (unused), the flags in the top 8
	blas:         u64,       // the bottom level's device address
}
#assert(size_of(Vk_Instance) == 64)

// VK_GEOMETRY_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT_KHR: a ray hits either side of a
// triangle, as our walk's Möller-Trumbore does.
@(private = "file")
VK_INSTANCE_CULL_DISABLE :: u32(1)

// The scratch memory builds work in, kept between builds and grown when one needs more.
// Builds that share it are ordered by the barrier each ends with.
@(private = "file")
vk_scratch: ^Vk_Buffer

vk_accel_track :: proc(cmd: ^Vk_Cmd, a: ^Vk_Accel) {
	if a.stamp == cmd.stamp do return
	a.stamp = cmd.stamp
	a.refs += 1
	append(&cmd.accels, a)
}

// Frees a released structure nothing uses any more, and lets go of its bottom levels.
vk_accel_reap :: proc(a: ^Vk_Accel) {
	if !a.released || a.refs > 0 do return
	vk.DestroyAccelerationStructureKHR(vk_state.device, a.handle, nil)
	vk_release_buffer(vk_device_handle(), (^sdl.GPUBuffer)(a.buffer))
	for b in a.instances {
		b.refs -= 1
		vk_accel_reap(b)
	}
	delete(a.instances)
	delete(a.geometries)
	free(a)
}

vk_release_accel :: proc(accel: ^Gpu_Accel) {
	a := (^Vk_Accel)(accel)
	a.released = true
	vk_accel_reap(a)
}

vk_accel_bytes :: proc(accel: ^Gpu_Accel) -> u64 {
	return (^Vk_Accel)(accel).bytes
}

// Frees the scratch memory, once the GPU is idle (vk_destroy_device).
vk_accel_destroy :: proc() {
	if vk_scratch != nil do vk_release_buffer(vk_device_handle(), (^sdl.GPUBuffer)(vk_scratch))
	vk_scratch = nil
}

@(private = "file")
vk_address :: proc(b: ^Vk_Buffer_Backing) -> vk.DeviceAddress {
	info := vk.BufferDeviceAddressInfo{sType = .BUFFER_DEVICE_ADDRESS_INFO, buffer = b.buffer}
	return vk.GetBufferDeviceAddress(vk_state.device, &info)
}

// Builds go on the graphics queue between passes: the compute queue would share the
// scratch memory with it unordered.
@(private = "file")
vk_accel_can_build :: proc(cmd: ^Vk_Cmd) -> bool {
	if cmd.pass != .None || cmd.queue != .Graphics {
		log.error("Vulkan: acceleration structures are built on the graphics queue, outside passes")
		return false
	}
	return true
}

// A structure of `size` bytes in a buffer of its own.
@(private = "file")
vk_accel_make :: proc(top: bool, size: vk.DeviceSize) -> ^Vk_Accel {
	if size > vk.DeviceSize(max(u32)) do return nil
	buffer := vk_buffer_make(u32(size), {.ACCELERATION_STRUCTURE_STORAGE_KHR, .SHADER_DEVICE_ADDRESS}, .None)
	if buffer == nil do return nil
	a := new(Vk_Accel)
	a.buffer, a.top, a.bytes = buffer, top, u64(size)
	info := vk.AccelerationStructureCreateInfoKHR {
		sType  = .ACCELERATION_STRUCTURE_CREATE_INFO_KHR,
		buffer = buffer.active.buffer,
		size   = size,
		type   = .TOP_LEVEL if top else .BOTTOM_LEVEL,
	}
	if vk.CreateAccelerationStructureKHR(vk_state.device, &info, nil, &a.handle) != .SUCCESS {
		vk_release_buffer(vk_device_handle(), (^sdl.GPUBuffer)(buffer))
		free(a)
		return nil
	}
	address := vk.AccelerationStructureDeviceAddressInfoKHR{sType = .ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR, accelerationStructure = a.handle}
	a.address = vk.GetAccelerationStructureDeviceAddressKHR(vk_state.device, &address)
	return a
}

// A scratch address with `size` bytes after it, aligned as builds need; 0 when the memory
// cannot be had.
@(private = "file")
vk_scratch_address :: proc(cmd: ^Vk_Cmd, size: vk.DeviceSize) -> vk.DeviceAddress {
	align := vk.DeviceSize(vk_state.scratch_align)
	need := size + align
	if vk_scratch == nil || vk.DeviceSize(vk_scratch.size) < need {
		if need > vk.DeviceSize(max(u32)) do return 0
		// The old scratch goes once the builds that used it are done.
		if vk_scratch != nil do vk_release_buffer(vk_device_handle(), (^sdl.GPUBuffer)(vk_scratch))
		vk_scratch = vk_buffer_make(u32(need), {.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS}, .None)
		if vk_scratch == nil do return 0
	}
	vk_cmd_track_buffer(cmd, vk_scratch.active)
	address := vk_address(vk_scratch.active)
	return (address + vk.DeviceAddress(align) - 1) / vk.DeviceAddress(align) * vk.DeviceAddress(align)
}

// Records one build and the barriers round it.
@(private = "file")
vk_accel_record :: proc(cmd: ^Vk_Cmd, info: ^vk.AccelerationStructureBuildGeometryInfoKHR, ranges: []vk.AccelerationStructureBuildRangeInfoKHR) {
	vk_memory_barrier(cmd)
	first := raw_data(ranges)
	vk.CmdBuildAccelerationStructuresKHR(cmd.cb, 1, info, &first)
	vk_memory_barrier(cmd)
}

vk_build_blas :: proc(command_buffer: ^sdl.GPUCommandBuffer, positions, indices: ^sdl.GPUBuffer, vertex_count: u32, geometries: []Blas_Geometry, update: ^Gpu_Accel) -> ^Gpu_Accel {
	cmd := (^Vk_Cmd)(command_buffer)
	if !vk_accel_can_build(cmd) || len(geometries) == 0 || vertex_count == 0 do return nil
	pos, idx := (^Vk_Buffer)(positions), (^Vk_Buffer)(indices)
	if .SHADER_DEVICE_ADDRESS not_in pos.usage || .SHADER_DEVICE_ADDRESS not_in idx.usage {
		log.error("Vulkan: an acceleration structure's vertices and indices need buffers made with accel_input")
		return nil
	}
	pos_address, idx_address := vk_address(pos.active), vk_address(idx.active)
	geoms := make([]vk.AccelerationStructureGeometryKHR, len(geometries), context.temp_allocator)
	ranges := make([]vk.AccelerationStructureBuildRangeInfoKHR, len(geometries), context.temp_allocator)
	counts := make([]u32, len(geometries), context.temp_allocator)
	for g, i in geometries {
		geoms[i] = {
			sType        = .ACCELERATION_STRUCTURE_GEOMETRY_KHR,
			geometryType = .TRIANGLES,
			flags        = {.OPAQUE} if g.opaque else {},
			geometry     = {triangles = {
				sType        = .ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR,
				vertexFormat = .R32G32B32_SFLOAT,
				vertexData   = {deviceAddress = pos_address},
				vertexStride = 12,
				maxVertex    = vertex_count - 1,
				indexType    = .UINT32,
				indexData    = {deviceAddress = idx_address},
			}},
		}
		ranges[i] = {primitiveCount = g.triangle_count, primitiveOffset = g.first_triangle * 12}
		counts[i] = g.triangle_count
	}
	old := (^Vk_Accel)(update)
	// A refit keeps every geometry's triangles and flags (VK_BUILD_ACCELERATION_STRUCTURE_MODE_UPDATE_KHR
	// allows only the vertices to move), so any other change is a new build.
	refit := old != nil && !old.top && old.vertex_count == vertex_count && slice.equal(old.geometries[:], geometries)
	info := vk.AccelerationStructureBuildGeometryInfoKHR {
		sType         = .ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR,
		type          = .BOTTOM_LEVEL,
		flags         = {.ALLOW_UPDATE, .PREFER_FAST_TRACE},
		mode          = .UPDATE if refit else .BUILD,
		geometryCount = u32(len(geoms)),
		pGeometries   = raw_data(geoms),
	}
	a := old if refit else nil
	if a == nil {
		sizes := vk.AccelerationStructureBuildSizesInfoKHR{sType = .ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR}
		vk.GetAccelerationStructureBuildSizesKHR(vk_state.device, .DEVICE, &info, raw_data(counts), &sizes)
		a = vk_accel_make(false, sizes.accelerationStructureSize)
		if a == nil do return nil
		a.build_scratch, a.update_scratch = sizes.buildScratchSize, sizes.updateScratchSize
		a.vertex_count = vertex_count
		append(&a.geometries, ..geometries)
	}
	scratch := vk_scratch_address(cmd, a.update_scratch if refit else a.build_scratch)
	if scratch == 0 {
		if !refit do vk_release_accel((^Gpu_Accel)(a))
		return nil
	}
	info.srcAccelerationStructure = a.handle if refit else 0
	info.dstAccelerationStructure = a.handle
	info.scratchData.deviceAddress = scratch
	vk_cmd_track_buffer(cmd, pos.active)
	vk_cmd_track_buffer(cmd, idx.active)
	vk_accel_track(cmd, a)
	vk_accel_record(cmd, &info, ranges)
	return (^Gpu_Accel)(a)
}

vk_build_tlas :: proc(command_buffer: ^sdl.GPUCommandBuffer, instances: []Tlas_Instance, update: ^Gpu_Accel) -> ^Gpu_Accel {
	cmd := (^Vk_Cmd)(command_buffer)
	if !vk_accel_can_build(cmd) || len(instances) == 0 do return nil
	// The instances go up through a buffer of this build's own, freed once it has run.
	upload := vk_buffer_make(u32(len(instances) * size_of(Vk_Instance)), {.SHADER_DEVICE_ADDRESS, .ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR}, .Upload)
	if upload == nil do return nil
	defer vk_release_buffer(vk_device_handle(), (^sdl.GPUBuffer)(upload))
	words := ([^]Vk_Instance)(upload.active.mapped)
	for inst, i in instances {
		t: [3][4]f32
		for row in 0 ..< 3 do for col in 0 ..< 4 do t[row][col] = inst.transform[row, col]
		words[i] = {
			transform    = t,
			custom_mask  = inst.custom & 0xFFFFFF | 0xFF << 24,
			offset_flags = VK_INSTANCE_CULL_DISABLE << 24,
			blas         = u64((^Vk_Accel)(inst.blas).address),
		}
	}
	geom := vk.AccelerationStructureGeometryKHR {
		sType        = .ACCELERATION_STRUCTURE_GEOMETRY_KHR,
		geometryType = .INSTANCES,
		geometry     = {instances = {sType = .ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR, data = {deviceAddress = vk_address(upload.active)}}},
	}
	// A top level is rebuilt every time, which costs little for a scene's few instances
	// and keeps its tree as good as a fresh one; only its memory is reused.
	info := vk.AccelerationStructureBuildGeometryInfoKHR {
		sType         = .ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR,
		type          = .TOP_LEVEL,
		flags         = {.PREFER_FAST_TRACE},
		mode          = .BUILD,
		geometryCount = 1,
		pGeometries   = &geom,
	}
	count := u32(len(instances))
	old := (^Vk_Accel)(update)
	a := old if old != nil && old.top && len(old.instances) == len(instances) else nil
	if a == nil {
		sizes := vk.AccelerationStructureBuildSizesInfoKHR{sType = .ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR}
		vk.GetAccelerationStructureBuildSizesKHR(vk_state.device, .DEVICE, &info, &count, &sizes)
		a = vk_accel_make(true, sizes.accelerationStructureSize)
		if a == nil do return nil
		a.build_scratch = sizes.buildScratchSize
	}
	scratch := vk_scratch_address(cmd, a.build_scratch)
	if scratch == 0 {
		if a != old do vk_release_accel((^Gpu_Accel)(a))
		return nil
	}
	// The new bottom levels are held before the old ones are let go, so one in both stays.
	held := a.instances
	a.instances = make([dynamic]^Vk_Accel, 0, len(instances))
	for inst in instances {
		b := (^Vk_Accel)(inst.blas)
		b.refs += 1
		append(&a.instances, b)
	}
	for b in held {
		b.refs -= 1
		vk_accel_reap(b)
	}
	delete(held)
	info.dstAccelerationStructure = a.handle
	info.scratchData.deviceAddress = scratch
	vk_cmd_track_buffer(cmd, upload.active)
	vk_accel_track(cmd, a)
	for b in a.instances do vk_accel_track(cmd, b)
	range := vk.AccelerationStructureBuildRangeInfoKHR{primitiveCount = count}
	vk_accel_record(cmd, &info, []vk.AccelerationStructureBuildRangeInfoKHR{range})
	return (^Gpu_Accel)(a)
}

// The top level the next dispatch traces against; it and every bottom level it instances
// stay alive until this command buffer has run.
vk_bind_compute_accel :: proc(compute_pass: ^sdl.GPUComputePass, accel: ^Gpu_Accel) {
	cmd := (^Vk_Cmd)(compute_pass)
	a := (^Vk_Accel)(accel)
	if a == nil || !a.top {
		log.error("Vulkan: a kernel traces against a top-level acceleration structure")
		return
	}
	vk_accel_track(cmd, a)
	for b in a.instances do vk_accel_track(cmd, b)
	cmd.accel = a.handle
	cmd.set_dirty[3] = true
}
