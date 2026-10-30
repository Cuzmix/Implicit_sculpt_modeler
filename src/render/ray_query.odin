package render

import "core:log"
import "core:math"
import "core:math/linalg"

import sdl "vendor:sdl3"

// The ray query check, run when the device is made under --gpu-debug where Gpu_Caps.ray_query
// is true: a bottom level over a fixture of two triangles (an opaque geometry and one that
// is not), a top level of two instances of it (one moved and scaled), and rays whose
// answers were worked out by hand: the distance along the unnormalised ray, the instance's
// number, the geometry, the triangle within it and the barycentrics, closest hits and hits
// from behind. It then moves the vertices, refits the bottom level and rebuilds the top one
// in place, and traces again. A wrong answer counts as a validation error, so smoke and
// parity_check.py fail on it.

Ray_Query_Check :: enum u8 {
	Not_Run,
	Passed,
	Failed,
}

when ODIN_OS != .Darwin {
	RAY_QUERY_CHECK_COMP_CODE :: #load("shaders/ray_query_check.comp.spv")
}

@(private = "file")
Rq_Ray :: struct {
	origin, direction: [3]f32,
	// What it hits in each round (before and after the vertices move up by 1): t is -1 for
	// a miss.
	t:                 [2]f32,
	instance:          u32,
	geometry:          u32,
	primitive:         u32,
	bary:              [2]f32,
}

// Instance A is the fixture where it is (number 7); B is it scaled by 2 and moved 4 down
// (number 300000, which needs more than 16 bits). The fixture is the square from (-1, -1)
// to (1, 1) at z = 0: triangle 0 (corners 0, 1, 2, below the diagonal) is geometry 0,
// opaque; triangle 1 (corners 0, 2, 3) is geometry 1, not opaque.
@(private = "file")
RQ_RAYS := [?]Rq_Ray {
	{origin = {0.5, -0.5, 5}, direction = {0, 0, -1}, t = {5, 4}, instance = 7, geometry = 0, primitive = 0, bary = {0.5, 0.25}},
	{origin = {-0.5, 0.5, 5}, direction = {0, 0, -1}, t = {5, 4}, instance = 7, geometry = 1, primitive = 0, bary = {0.25, 0.5}},
	// Past A's edge, onto B.
	{origin = {1.5, -1, 5}, direction = {0, 0, -1}, t = {9, 7}, instance = 300000, geometry = 0, primitive = 0, bary = {0.625, 0.25}},
	// Away from both.
	{origin = {0, 0, 5}, direction = {0, 0, 1}, t = {-1, -1}},
	// t is the parameter of the ray as given, not a distance.
	{origin = {0.5, -0.5, 5}, direction = {0, 0, -2}, t = {2.5, 2}, instance = 7, geometry = 0, primitive = 0, bary = {0.5, 0.25}},
	// From below: B's back face first, then A's.
	{origin = {0.5, -0.5, -10}, direction = {0, 0, 1}, t = {6, 8}, instance = 300000, geometry = 0, primitive = 0, bary = {0.25, 0.375}},
}

@(private = "file")
RQ_INDICES := [6]u32{0, 1, 2, 0, 2, 3}

// Runs the check and logs what it found.
ray_query_check :: proc(r: ^Renderer) -> Ray_Query_Check {
	if !r.caps.ray_query do return .Not_Run
	ok := ray_query_check_run(r)
	if ok {
		log.info("ray query check: passed")
	} else {
		vk_validation_error("the ray query check failed")
	}
	return .Passed if ok else .Failed
}

@(private = "file")
ray_query_check_run :: proc(r: ^Renderer) -> bool {
	RAYS :: len(RQ_RAYS)
	positions := gpu_create_buffer(r.device, {usage = {.VERTEX}, size = 4 * 12}, accel_input = true)
	indices := gpu_create_buffer(r.device, {usage = {.INDEX}, size = size_of(RQ_INDICES)}, accel_input = true)
	rays := gpu_create_buffer(r.device, {usage = {.COMPUTE_STORAGE_READ}, size = RAYS * 32})
	hits := gpu_create_buffer(r.device, {usage = {.COMPUTE_STORAGE_WRITE}, size = RAYS * 32})
	upload := gpu_create_transfer_buffer(r.device, {usage = .UPLOAD, size = 4 * 12 + size_of(RQ_INDICES) + RAYS * 32})
	download := gpu_create_transfer_buffer(r.device, {usage = .DOWNLOAD, size = RAYS * 32})
	// Ray queries are never offered on Apple's platforms, which have no SPIR-V of the kernel.
	pipeline: ^sdl.GPUComputePipeline
	when ODIN_OS != .Darwin {
		pipeline = gpu_create_compute_pipeline_traced(r.device, {
			code_size = len(RAY_QUERY_CHECK_COMP_CODE), code = raw_data(RAY_QUERY_CHECK_COMP_CODE), entrypoint = SHADER_ENTRY,
			format = SHADER_FORMAT, num_readonly_storage_buffers = 1, num_readwrite_storage_buffers = 1, num_uniform_buffers = 1,
			threadcount_x = 64, threadcount_y = 1, threadcount_z = 1,
		})
	}
	blas, tlas: ^Gpu_Accel
	defer {
		gpu_release_accel(r.device, tlas)
		gpu_release_accel(r.device, blas)
		gpu_release_compute_pipeline(r.device, pipeline)
		gpu_release_transfer_buffer(r.device, download)
		gpu_release_transfer_buffer(r.device, upload)
		gpu_release_buffer(r.device, hits)
		gpu_release_buffer(r.device, rays)
		gpu_release_buffer(r.device, indices)
		gpu_release_buffer(r.device, positions)
	}
	if positions == nil || indices == nil || rays == nil || hits == nil || upload == nil || download == nil || pipeline == nil {
		log.errorf("ray query check: its buffers or kernel could not be made (%s)", sdl.GetError())
		return false
	}
	geometries := [2]Blas_Geometry{{first_triangle = 0, triangle_count = 1, opaque = true}, {first_triangle = 1, triangle_count = 1, opaque = false}}
	for round in 0 ..< 2 {
		// The first round fills everything; the second moves the vertices up by 1.
		z := f32(round)
		data := ([^]u8)(gpu_map_transfer_buffer(r.device, upload, true))
		if data == nil do return false
		corners := [4][3]f32{{-1, -1, z}, {1, -1, z}, {1, 1, z}, {-1, 1, z}}
		copy(data[:4 * 12], ([^]u8)(&corners)[:4 * 12])
		copy(data[48:48 + size_of(RQ_INDICES)], ([^]u8)(&RQ_INDICES)[:size_of(RQ_INDICES)])
		ray_words := ([^][4]f32)(&data[48 + size_of(RQ_INDICES)])
		for ray, i in RQ_RAYS {
			ray_words[2 * i] = {ray.origin.x, ray.origin.y, ray.origin.z, 0}
			ray_words[2 * i + 1] = {ray.direction.x, ray.direction.y, ray.direction.z, 0}
		}
		gpu_unmap_transfer_buffer(r.device, upload)
		cmd := gpu_acquire_command_buffer(r.device)
		if cmd == nil do return false
		copy_pass := gpu_begin_copy_pass(cmd)
		gpu_upload_to_buffer(copy_pass, {transfer_buffer = upload}, {buffer = positions, size = 48}, false)
		gpu_upload_to_buffer(copy_pass, {transfer_buffer = upload, offset = 48}, {buffer = indices, size = size_of(RQ_INDICES)}, false)
		gpu_upload_to_buffer(copy_pass, {transfer_buffer = upload, offset = 48 + size_of(RQ_INDICES)}, {buffer = rays, size = RAYS * 32}, false)
		gpu_end_copy_pass(copy_pass)
		new_blas := gpu_build_blas(cmd, positions, indices, 4, geometries[:], blas)
		if round == 1 && new_blas != blas {
			log.error("ray query check: the refit made a new bottom level")
			if new_blas != nil do gpu_release_accel(r.device, new_blas)
			_ = gpu_submit_command_buffer(cmd)
			return false
		}
		blas = new_blas
		instances := [2]Tlas_Instance {
			{blas = blas, transform = 1, custom = 7},
			{blas = blas, transform = linalg.matrix4_translate_f32({0, 0, -4}) * linalg.matrix4_scale_f32({2, 2, 2}), custom = 300000},
		}
		new_tlas: ^Gpu_Accel
		if blas != nil do new_tlas = gpu_build_tlas(cmd, instances[:], tlas)
		if round == 1 && new_tlas != tlas {
			log.error("ray query check: the top level was not rebuilt in place")
			if new_tlas != nil do gpu_release_accel(r.device, new_tlas)
			_ = gpu_submit_command_buffer(cmd)
			return false
		}
		tlas = new_tlas
		if tlas == nil {
			log.error("ray query check: the acceleration structures could not be built")
			_ = gpu_submit_command_buffer(cmd)
			return false
		}
		write := sdl.GPUStorageBufferReadWriteBinding{buffer = hits}
		pass := gpu_begin_compute_pass(cmd, nil, 0, &write, 1)
		gpu_bind_compute_pipeline(pass, pipeline)
		gpu_bind_compute_storage_buffers(pass, 0, &rays, 1)
		gpu_bind_compute_accel(pass, tlas)
		count := u32(RAYS)
		gpu_push_compute_uniform_data(cmd, 0, &count, size_of(count))
		gpu_dispatch_compute(pass, 1, 1, 1)
		gpu_end_compute_pass(pass)
		copy_pass = gpu_begin_copy_pass(cmd)
		gpu_download_from_buffer(copy_pass, {buffer = hits, size = RAYS * 32}, {transfer_buffer = download})
		gpu_end_copy_pass(copy_pass)
		if !gpu_submit_command_buffer(cmd) || !gpu_wait_for_idle(r.device) do return false
		got := ([^][4]f32)(gpu_map_transfer_buffer(r.device, download, false))
		if got == nil do return false
		ok := true
		for ray, i in RQ_RAYS {
			hit, bary := got[2 * i], got[2 * i + 1]
			want_t := ray.t[round]
			close :: proc(a, b: f32) -> bool {return math.abs(a - b) <= 1e-4 * max(1, math.abs(b))}
			right := close(hit[0], want_t)
			if want_t >= 0 do right = right && u32(hit[1]) == ray.instance && u32(hit[2]) == ray.primitive && u32(hit[3]) == ray.geometry && close(bary[0], ray.bary[0]) && close(bary[1], ray.bary[1])
			if !right {
				log.errorf("ray query check: round %d ray %d hit t=%v instance=%v primitive=%v geometry=%v barycentrics=%v, not t=%v instance=%v primitive=%v geometry=%v barycentrics=%v", round, i, hit[0], hit[1], hit[2], hit[3], bary.xy, want_t, ray.instance, ray.primitive, ray.geometry, ray.bary)
				ok = false
			}
		}
		gpu_unmap_transfer_buffer(r.device, download)
		if !ok do return false
	}
	return true
}
