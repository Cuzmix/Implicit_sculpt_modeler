#+build darwin
package gpu

import "core:log"
import "core:slice"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

// Ray tracing under the own Metal backend (native GPU plan 6.4,
// notes/native-gpu/metal-ray-tracing-design.md): Metal's acceleration structures, built as
// the Vulkan backend builds them (vk_accel.odin) and traced by the same kernels, whose Metal
// source slangc makes as every shader's (scripts/shaders_msl.py). Apple's GPUs from the A14 and M1 trace in software and
// the M3 and A17 Pro in hardware; the app offers it on any of them, off by default on
// Apple's platforms, and checks it against the ray query check's known answers before the
// first kernel traces (ray_query_trusted).
//
// Metal tracks hazards on the structures as on any resource, so builds need no barriers, and
// a command buffer keeps alive whatever it encoded; each command buffer also retains every
// structure, scratch and instance buffer it used (Mtl_Cmd.kept), so a structure released
// while the GPU still traces it lives until that command buffer has run.

Mtl_Accel :: struct {
	accel:         ^MTL.AccelerationStructure,
	top:           bool,
	bytes:         u64,
	// A bottom level's geometries and vertex count as built: a refit must keep both.
	geometries:    [dynamic]Blas_Geometry,
	vertex_count:  u32,
	refit_scratch: NS.UInteger,
	// A top level's bottom levels, each holding one reference from it.
	instances:     [dynamic]^Mtl_Accel,
	// The app's hold until it releases the structure, plus one for each top level naming it.
	refs:          i32,
}

// MTLAccelerationStructureUserIDInstanceDescriptor, whose user ID the kernels read back as
// the instance's number (CommittedInstanceID, Tlas_Instance.custom).
@(private = "file")
Mtl_Instance :: struct {
	transform:      [4][3]f32, // MTLPackedFloat4x3: the four columns of the top three rows
	options:        MTL.AccelerationStructureInstanceOptions,
	mask:           u32,
	function_table: u32,
	structure:      u32, // into the descriptor's instancedAccelerationStructures
	user_id:        u32,
}
#assert(size_of(Mtl_Instance) == 68)

// Whether fragment shaders can read barycentric coordinates (barycentric_offered):
// Apple silicon and recent Macs' GPUs.
mtl_barycentric_offered :: proc() -> bool {
	if mtl_state.device == nil do return false
	return bool(MTL.Device_supportsShaderBarycentricCoordinates(mtl_state.device))
}

// Metal 3 (A14, M1 and later), whose buffers have the GPU addresses the studio's kernel reads
// indices through, and ray tracing.
mtl_ray_query_offered :: proc() -> bool {
	if mtl_state.device == nil do return false
	return bool(MTL.Device_supportsFamily(mtl_state.device, .Metal3)) && bool(MTL.Device_supportsRaytracing(mtl_state.device))
}

// Keeps `object` retained until the command buffer has run.
@(private = "file")
mtl_cmd_keep :: proc(cmd: ^Mtl_Cmd, object: ^NS.Object) {
	NS.retain(object)
	append(&cmd.kept, object)
}

@(private = "file")
mtl_accel_unref :: proc(a: ^Mtl_Accel) {
	a.refs -= 1
	if a.refs > 0 do return
	for b in a.instances do mtl_accel_unref(b)
	delete(a.instances)
	delete(a.geometries)
	NS.release(a.accel)
	free(a)
}

mtl_release_accel :: proc(accel: ^Gpu_Accel) {
	if accel != nil do mtl_accel_unref((^Mtl_Accel)(accel))
}

mtl_accel_bytes :: proc(accel: ^Gpu_Accel) -> u64 {
	return (^Mtl_Accel)(accel).bytes
}

// Builds go outside passes, in an encoder of their own.
@(private = "file")
mtl_accel_can_build :: proc(cmd: ^Mtl_Cmd) -> bool {
	if cmd.render != nil || cmd.blit != nil || cmd.compute != nil {
		log.error("Metal: acceleration structures are built outside passes")
		return false
	}
	return true
}

// A private buffer of `size` bytes for one build to work in, kept by `cmd` until it has run.
@(private = "file")
mtl_scratch :: proc(cmd: ^Mtl_Cmd, size: NS.UInteger) -> ^MTL.Buffer {
	buffer := MTL.Device_newBufferWithLength(mtl_state.device, max(size, 4), {.StorageModePrivate})
	if buffer == nil do return nil
	mtl_cmd_keep(cmd, buffer)
	NS.release(buffer)
	return buffer
}

mtl_build_blas :: proc(command_buffer: Cmd, positions, indices: Buffer, vertex_count: u32, geometries: []Blas_Geometry, update: ^Gpu_Accel) -> ^Gpu_Accel {
	NS.scoped_autoreleasepool()
	cmd := (^Mtl_Cmd)(command_buffer)
	if !mtl_accel_can_build(cmd) || len(geometries) == 0 || vertex_count == 0 do return nil
	pos, idx := (^Mtl_Buffer)(object(positions)).active, (^Mtl_Buffer)(object(indices)).active
	descs := make([]^NS.Object, len(geometries), context.temp_allocator)
	for g, i in geometries {
		d := MTL.AccelerationStructureTriangleGeometryDescriptor_descriptor()
		MTL.AccelerationStructureTriangleGeometryDescriptor_setVertexBuffer(d, pos.buffer)
		MTL.AccelerationStructureTriangleGeometryDescriptor_setVertexStride(d, 12)
		MTL.AccelerationStructureTriangleGeometryDescriptor_setIndexBuffer(d, idx.buffer)
		MTL.AccelerationStructureTriangleGeometryDescriptor_setIndexType(d, .UInt32)
		MTL.AccelerationStructureTriangleGeometryDescriptor_setIndexBufferOffset(d, NS.UInteger(g.first_triangle) * 12)
		MTL.AccelerationStructureTriangleGeometryDescriptor_setTriangleCount(d, NS.UInteger(g.triangle_count))
		MTL.AccelerationStructureGeometryDescriptor_setOpaque((^MTL.AccelerationStructureGeometryDescriptor)(d), NS.BOOL(g.opaque))
		descs[i] = d
	}
	array := NS.Array_initWithObjects(NS.Array_alloc(), raw_data(descs), NS.UInteger(len(descs)))
	defer NS.release(array)
	desc := MTL.PrimitiveAccelerationStructureDescriptor_descriptor()
	MTL.PrimitiveAccelerationStructureDescriptor_setGeometryDescriptors(desc, array)
	MTL.AccelerationStructureDescriptor_setUsage(desc, {.Refit})

	old := (^Mtl_Accel)(update)
	// A refit keeps every geometry's triangles and flags; only the vertices move.
	refit := old != nil && !old.top && old.vertex_count == vertex_count && slice.equal(old.geometries[:], geometries)
	a := old if refit else nil
	build_scratch: NS.UInteger
	if a == nil {
		sizes := MTL.Device_accelerationStructureSizesWithDescriptor(mtl_state.device, desc)
		accel := MTL.Device_newAccelerationStructureWithSize(mtl_state.device, NS.UInteger(sizes.accelerationStructureSize))
		if accel == nil do return nil
		a = new(Mtl_Accel)
		a.accel, a.refs, a.bytes = accel, 1, u64(sizes.accelerationStructureSize)
		a.vertex_count, a.refit_scratch = vertex_count, NS.UInteger(sizes.refitScratchBufferSize)
		append(&a.geometries, ..geometries)
		build_scratch = NS.UInteger(sizes.buildScratchBufferSize)
	}
	scratch := mtl_scratch(cmd, a.refit_scratch if refit else build_scratch)
	enc := MTL.CommandBuffer_accelerationStructureCommandEncoder(cmd.cb)
	cmd.recorded = cmd.recorded || enc != nil
	if scratch == nil || enc == nil {
		if !refit do mtl_accel_unref(a)
		return nil
	}
	if refit {
		// No destination: the structure is refitted in place.
		MTL.AccelerationStructureCommandEncoder_refitAccelerationStructure(enc, a.accel, desc, nil, scratch, 0)
	} else {
		MTL.AccelerationStructureCommandEncoder_buildAccelerationStructure(enc, a.accel, desc, scratch, 0)
	}
	MTL.CommandEncoder_endEncoding(enc)
	mtl_cmd_track_buffer(cmd, pos)
	mtl_cmd_track_buffer(cmd, idx)
	mtl_cmd_keep(cmd, a.accel)
	return (^Gpu_Accel)(a)
}

mtl_build_tlas :: proc(command_buffer: Cmd, instances: []Tlas_Instance, update: ^Gpu_Accel) -> ^Gpu_Accel {
	NS.scoped_autoreleasepool()
	cmd := (^Mtl_Cmd)(command_buffer)
	if !mtl_accel_can_build(cmd) || len(instances) == 0 do return nil
	// The bottom levels named, each once, in the order first named.
	blases := make([dynamic]^Mtl_Accel, context.temp_allocator)
	objects := make([dynamic]^NS.Object, context.temp_allocator)
	words := make([]Mtl_Instance, len(instances), context.temp_allocator)
	for inst, i in instances {
		b := (^Mtl_Accel)(inst.blas)
		at, found := slice.linear_search(blases[:], b)
		if !found {
			at = len(blases)
			append(&blases, b)
			append(&objects, b.accel)
		}
		w := Mtl_Instance{options = {.DisableTriangleCulling}, mask = 0xFF, structure = u32(at), user_id = inst.custom}
		for col in 0 ..< 4 do for row in 0 ..< 3 do w.transform[col][row] = inst.transform[row, col]
		words[i] = w
	}
	// No options is shared storage, which the CPU writes and the build then reads.
	upload := MTL.Device_newBufferWithLength(mtl_state.device, NS.UInteger(len(words) * size_of(Mtl_Instance)), {})
	if upload == nil do return nil
	mtl_cmd_keep(cmd, upload)
	NS.release(upload)
	copy(([^]Mtl_Instance)(raw_data(MTL.Buffer_contents(upload)))[:len(words)], words)
	array := NS.Array_initWithObjects(NS.Array_alloc(), raw_data(objects), NS.UInteger(len(objects)))
	defer NS.release(array)
	desc := MTL.InstanceAccelerationStructureDescriptor_descriptor()
	MTL.InstanceAccelerationStructureDescriptor_setInstancedAccelerationStructures(desc, array)
	MTL.InstanceAccelerationStructureDescriptor_setInstanceCount(desc, NS.UInteger(len(words)))
	MTL.InstanceAccelerationStructureDescriptor_setInstanceDescriptorBuffer(desc, upload)
	MTL.InstanceAccelerationStructureDescriptor_setInstanceDescriptorType(desc, .UserID)
	MTL.InstanceAccelerationStructureDescriptor_setInstanceDescriptorStride(desc, size_of(Mtl_Instance))

	// A top level is rebuilt every time, into the old one's memory when it is big enough.
	sizes := MTL.Device_accelerationStructureSizesWithDescriptor(mtl_state.device, desc)
	old := (^Mtl_Accel)(update)
	a := old if old != nil && old.top && old.bytes >= u64(sizes.accelerationStructureSize) else nil
	if a == nil {
		accel := MTL.Device_newAccelerationStructureWithSize(mtl_state.device, NS.UInteger(sizes.accelerationStructureSize))
		if accel == nil do return nil
		a = new(Mtl_Accel)
		a.accel, a.refs, a.top, a.bytes = accel, 1, true, u64(sizes.accelerationStructureSize)
	}
	scratch := mtl_scratch(cmd, NS.UInteger(sizes.buildScratchBufferSize))
	enc := MTL.CommandBuffer_accelerationStructureCommandEncoder(cmd.cb)
	cmd.recorded = cmd.recorded || enc != nil
	if scratch == nil || enc == nil {
		if a != old do mtl_accel_unref(a)
		return nil
	}
	// The new bottom levels are held before the old ones are let go, so one in both stays.
	held := a.instances
	a.instances = make([dynamic]^Mtl_Accel, 0, len(blases))
	for b in blases {
		b.refs += 1
		append(&a.instances, b)
	}
	for b in held do mtl_accel_unref(b)
	delete(held)
	MTL.AccelerationStructureCommandEncoder_buildAccelerationStructure(enc, a.accel, desc, scratch, 0)
	MTL.CommandEncoder_endEncoding(enc)
	mtl_cmd_keep(cmd, a.accel)
	for b in a.instances do mtl_cmd_keep(cmd, b.accel)
	return (^Gpu_Accel)(a)
}

// The top level the next dispatch traces against, at the slot the pipeline's table names.
// Metal sees only the top level bound, so each bottom level it instances, and each buffer a
// kernel reads through its address (mtl_buffer_address), is declared used by the pass.
mtl_bind_compute_accel :: proc(compute_pass: Compute_Pass, accel: ^Gpu_Accel) {
	cmd := (^Mtl_Cmd)(compute_pass)
	a := (^Mtl_Accel)(accel)
	p := cmd.compute_pipeline
	if a == nil || !a.top || p == nil || p.slots.accel < 0 {
		log.error("Metal: a kernel traces against a top-level acceleration structure, bound after its pipeline")
		return
	}
	enc := cmd.compute
	mtl_cmd_keep(cmd, a.accel)
	MTL.ComputeCommandEncoder_setAccelerationStructure(enc, a.accel, NS.UInteger(p.slots.accel))
	for b in a.instances do MTL.ComputeCommandEncoder_useResource(enc, b.accel, {.Read})
	for buffer in cmd.addressed do MTL.ComputeCommandEncoder_useResource(enc, buffer, {.Read})
}

// The buffer's GPU address, which `command_buffer` keeps alive and its traced passes declare
// used.
mtl_buffer_address :: proc(command_buffer: Cmd, buffer: Buffer) -> u64 {
	cmd := (^Mtl_Cmd)(command_buffer)
	b := (^Mtl_Buffer)(object(buffer)).active
	mtl_cmd_track_buffer(cmd, b)
	if !slice.contains(cmd.addressed[:], b.buffer) do append(&cmd.addressed, b.buffer)
	return MTL.Buffer_gpuAddress(b.buffer)
}

// A traced kernel's pipeline: one whose slot table (scripts/shaders_msl.py) names the
// acceleration structure it traces against.
mtl_create_compute_pipeline_traced :: proc(#by_ptr info: Compute_Pipeline_Desc) -> rawptr {
	slots, ok := mtl_slots_parse(info.code)
	if !ok || slots.accel < 0 {
		fail(.Invalid, "Metal: a traced kernel's slot table names no acceleration structure")
		return nil
	}
	return mtl_create_compute_pipeline(info)
}
